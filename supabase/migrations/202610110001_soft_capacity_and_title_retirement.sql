begin;

-- Physical bed numbers are no longer an operational record.  The store keeps
-- a configurable simultaneous-service guideline and may accept a booking over
-- that guideline when another qualified technician is genuinely available.
alter table public.spa_settings
 add column if not exists simultaneous_capacity int not null default 4;
alter table public.spa_settings drop constraint if exists spa_settings_simultaneous_capacity_check;
alter table public.spa_settings add constraint spa_settings_simultaneous_capacity_check
 check (simultaneous_capacity between 1 and 20);

alter table public.spa_appointments alter column room_id drop not null;
alter table public.spa_appointments
 add column if not exists capacity_attention_required boolean not null default false,
 add column if not exists capacity_count_snapshot int,
 add column if not exists capacity_limit_snapshot int;

-- Keep historic room foreign keys intact, but remove beds 1-4 from every
-- current workflow.  New allocations intentionally store no room number.
update public.spa_rooms set active=false where active;

-- The removed title stays as an archived catalogue key so historic payroll,
-- appointments and reviews remain auditable.  Current assignees must be mapped
-- explicitly to one of the real seven technician levels before serving again.
update public.spa_staff
set title='舊職稱（待重新設定）',is_bookable=false,website_visible=false
where job_title_id=(select id from public.spa_job_titles where code='head_therapist');
update public.spa_job_titles
set name='舊職稱（待重新設定）',name_en='Retired title — reassignment required',
 active=false,legacy=true,work_category='legacy',allowed_employment_types='{}'::text[],
 archived_at=coalesce(archived_at,now())
where code='head_therapist';
update public.spa_payroll_runs set needs_recalculation=true where status='draft';

-- Peak simultaneous guests use the actual treatment interval [start,end).
-- Technician collision protection separately continues through blocked_until.
create or replace function spa_private.capacity_peak(p_start timestamptz,p_end timestamptz,p_exclude uuid default null)
returns int language sql stable security definer set search_path='' as $$
 with relevant as (
  select a.id,a.starts_at,a.ends_at from public.spa_appointments a
  where a.status in ('pending','confirmed','checked_in','in_service')
   and (p_exclude is null or a.id<>p_exclude)
   and a.starts_at<p_end and a.ends_at>p_start
 ), points as (
  select p_start point
  union select greatest(r.starts_at,p_start) from relevant r
 ), totals as (
  select count(r.id)::int n from points p left join relevant r
   on r.starts_at<=p.point and r.ends_at>p.point group by p.point
 )
 select coalesce(max(n),0)::int from totals
$$;

create or replace function spa_private.capacity_exceeded(p_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(a.capacity_attention_required,false)
  and a.status in ('pending','confirmed','checked_in','in_service')
  and spa_private.capacity_peak(a.starts_at,a.ends_at,null)>(select simultaneous_capacity from public.spa_settings limit 1)
 from public.spa_appointments a where a.id=p_id
$$;
revoke all on function spa_private.capacity_peak(timestamptz,timestamptz,uuid),spa_private.capacity_exceeded(uuid) from public,anon,authenticated;

create or replace function spa_private.candidates(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings), hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes) finish,p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s)
 select st.id,null::uuid,t.finish,t.blocked from public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
 cross join cfg cross join hours h cross join timing t
 where h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable
  and (p_staff is null or st.id=p_staff)
  and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
  and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
  and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
  and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed')
   and a.staff_id=st.id and a.starts_at<t.blocked and a.blocked_until>p_start)
 order by coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),0),st.display_order
$$;

create or replace function spa_private.available_staff_count(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns int language sql stable security definer set search_path='' as $$
 select count(*)::int from spa_private.candidates(p_service,p_date,p_start,p_staff)
$$;

create or replace function spa_private.guard_appointment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(726001);
 if new.status in ('pending','confirmed','checked_in','in_service','completed') then
  if exists(select 1 from public.spa_appointments a where a.id<>new.id
   and a.status in ('pending','confirmed','checked_in','in_service','completed')
   and a.staff_id=new.staff_id and a.starts_at<new.blocked_until and a.blocked_until>new.starts_at)
  then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 end if;
 new.updated_at=now(); return new;
end $$;

create or replace function spa_private.reschedule_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid,p_require_public boolean default true)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select st.id,null::uuid,p_start+(a.ends_at-a.starts_at),p_start+(a.blocked_until-a.starts_at)
 from public.spa_appointments a join public.spa_services svc on svc.id=a.service_id
 cross join public.spa_settings cfg cross join spa_private.business_window(p_date) h cross join public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=a.service_id and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
 where a.id=p_id and (not p_require_public or (svc.active and svc.status='active' and svc.online_booking_enabled))
  and h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable
  and (p_staff is null or st.id=p_staff)
  and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
  and p_start+(a.blocked_until-a.starts_at)<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
  and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<p_start+(a.blocked_until-a.starts_at) and o.ends_at>p_start)
  and not exists(select 1 from public.spa_appointments other where other.id<>a.id
   and other.status in ('pending','confirmed','checked_in','in_service','completed')
   and other.staff_id=st.id and other.starts_at<p_start+(a.blocked_until-a.starts_at) and other.blocked_until>p_start)
 order by coalesce((select sum(b.duration_minutes_snapshot) from public.spa_appointments b where b.staff_id=st.id and b.business_date=p_date and b.id<>a.id and b.status not in ('cancelled','no_show')),0),st.display_order
$$;

-- Customer availability and customer-initiated rescheduling use the same
-- technician-only allocation rules.  Replacing this wrapper is essential:
-- the previous version still required one of the now-retired active beds.
create or replace function spa_private.customer_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select * from spa_private.reschedule_candidates(p_id,p_date,p_start,p_staff,true)
$$;

create or replace function spa_private.booking_summary(a public.spa_appointments)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',a.id,'reference',a.reference,'service_id',a.service_id,'service_name',coalesce(a.service_name_snapshot,a.service_name),
 'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,'staff_id',a.staff_id,
 'therapist',st.name,'therapist_title',j.name,'therapist_title_en',j.name_en,'price_cents',a.price_cents+a.tea_cents,
 'change_before',a.starts_at-make_interval(hours=>cfg.cancellation_hours),'can_change',a.status in ('pending','confirmed') and a.starts_at>=now()+make_interval(hours=>cfg.cancellation_hours),
 'can_review',a.status='completed' and not exists(select 1 from public.spa_reviews where appointment_id=a.id),
 'review_submitted',exists(select 1 from public.spa_reviews where appointment_id=a.id),
 'capacity_attention_required',spa_private.capacity_exceeded(a.id),'capacity_count',a.capacity_count_snapshot,'capacity_limit',coalesce(a.capacity_limit_snapshot,cfg.simultaneous_capacity))
 from public.spa_settings cfg join public.spa_staff st on st.id=a.staff_id join public.spa_job_titles j on j.id=st.job_title_id
$$;

create or replace function public.spa_create_booking(p_request uuid,p_service uuid,p_date date,p_start timestamptz,p_staff uuid,p_name text,p_phone text,p_tea int default 0,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; svc public.spa_services; slot record; customer public.spa_customers; booking public.spa_appointments; tel text; minute int; assigned_name text; predicted int; attention boolean;
begin
 perform pg_advisory_xact_lock(726001); tel:=spa_private.phone(p_phone);
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 80 or tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_tea is null or p_tea not between 0 and 4 or length(coalesce(p_note,''))>1000 then raise exception 'INVALID_INPUT'; end if;
 select * into customer from public.spa_customers where phone=tel for update;
 if found then
  if lower(btrim(customer.name))<>lower(btrim(p_name)) then raise exception 'CUSTOMER_NAME_MISMATCH'; end if;
  if customer.status<>'active' or customer.archived_at is not null then raise exception 'CUSTOMER_UNAVAILABLE'; end if;
 end if;
 select * into booking from public.spa_appointments where request_id=p_request;
 if found then
  if booking.customer_id is distinct from customer.id or booking.service_id is distinct from p_service
   or booking.business_date is distinct from p_date or booking.starts_at is distinct from p_start
   or booking.requested_staff_id is distinct from p_staff or booking.tea_code is distinct from p_tea
   or booking.note is distinct from coalesce(p_note,'') then raise exception 'REQUEST_CONFLICT'; end if;
  select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
  return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference,
   'capacity_attention_required',spa_private.capacity_exceeded(booking.id),'capacity_count',booking.capacity_count_snapshot,'capacity_limit',coalesce(booking.capacity_limit_snapshot,(select simultaneous_capacity from public.spa_settings limit 1)));
 end if;
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 select * into svc from public.spa_services where id=p_service and active and status='active' and online_booking_enabled;
 if not found then raise exception 'INVALID_SERVICE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.booking_last_date() or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 if customer.id is not null and (select count(*) from public.spa_appointments where customer_id=customer.id and created_at>now()-interval '24 hours')>=5 then raise exception 'RATE_LIMIT'; end if;
 select * into slot from spa_private.candidates(p_service,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 predicted:=spa_private.capacity_peak(p_start,slot.ends_at,null)+1; attention:=predicted>cfg.simultaneous_capacity;
 if customer.id is null then insert into public.spa_customers(name,phone) values(btrim(p_name),tel) returning * into customer; end if;
 insert into public.spa_appointments(request_id,customer_id,staff_id,requested_staff_id,booking_preference,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note,capacity_attention_required,capacity_count_snapshot,capacity_limit_snapshot)
 values(p_request,customer.id,slot.staff_id,p_staff,case when p_staff is null then 'any' else 'designated' end,null,p_service,p_date,p_start,slot.ends_at,slot.blocked_until,case when attention or not cfg.auto_confirm then 'pending' else 'confirmed' end,svc.name,svc.price_cents,p_tea,(array[0,12000,15000,12000,18000])[p_tea+1],coalesce(p_note,''),attention,predicted,cfg.simultaneous_capacity) returning * into booking;
 select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
 perform spa_private.audit('booking.created',booking.id::text,jsonb_build_object('source',case when spa_private.has_permission('appointments.manage') then 'admin' else 'website' end,'preference',booking.booking_preference,'requested_staff_id',p_staff,'assigned_staff_id',booking.staff_id,'capacity_count',predicted,'capacity_limit',cfg.simultaneous_capacity,'capacity_attention_required',attention));
 return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference,'capacity_attention_required',attention,'capacity_count',predicted,'capacity_limit',cfg.simultaneous_capacity);
end $$;

-- Confirming an over-capacity booking means the owner has completed the phone
-- coordination.  The slot can still show a physical peak above the guideline,
-- while the per-booking action warning and owner todo are resolved.
create or replace function public.spa_set_status(p_id uuid,p_status text,p_reason text default '') returns void
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if not ((a.status='pending' and p_status in ('confirmed','cancelled')) or (a.status='confirmed' and p_status in ('checked_in','cancelled','no_show')) or (a.status='checked_in' and p_status in ('in_service','completed')) or (a.status='in_service' and p_status='completed')) then raise exception 'INVALID_TRANSITION'; end if;
 if p_status in ('cancelled','no_show') and length(btrim(coalesce(p_reason,'')))=0 then raise exception 'REASON_REQUIRED'; end if;
 if p_status in ('checked_in','in_service','completed','no_show') and a.starts_at>now() then raise exception 'TOO_EARLY'; end if;
 update public.spa_appointments set status=p_status,
  cancellation_reason=case when p_status in ('cancelled','no_show') then p_reason else cancellation_reason end,
  capacity_attention_required=false where id=p_id;
 perform spa_private.audit('booking.'||p_status,p_id::text,jsonb_build_object('from',a.status,'reason',p_reason,'capacity_attention_resolved',a.capacity_attention_required));
end $$;

create or replace function public.spa_customer_reschedule(p_access uuid,p_appointment uuid,p_request uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; saved public.spa_booking_actions; cfg public.spa_settings; hours record; slot record; minute int; payload jsonb; result jsonb; old_start timestamptz; predicted int; attention boolean;
begin
 perform pg_advisory_xact_lock(726001); a:=spa_private.access_appointment(p_access,p_appointment);
 if p_request is null or p_reason is null or length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 payload:=jsonb_build_object('kind','reschedule','date',p_date,'start',p_start,'staff',p_staff,'reason',btrim(p_reason));
 select * into saved from public.spa_booking_actions where request_id=p_request;
 if found then if saved.customer_id<>a.customer_id or saved.appointment_id<>a.id or saved.payload<>payload then raise exception 'REQUEST_CONFLICT'; end if; return saved.result; end if;
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if a.status not in ('pending','confirmed') then raise exception 'INVALID_TRANSITION'; end if;
 if a.starts_at<now()+make_interval(hours=>cfg.cancellation_hours) then raise exception 'RESCHEDULE_CUTOFF'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.public_booking_last_date() or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 select * into slot from spa_private.customer_candidates(a.id,p_date,p_start,p_staff) limit 1; if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 old_start:=a.starts_at;
 if a.starts_at<>p_start or a.staff_id<>slot.staff_id then
  predicted:=spa_private.capacity_peak(p_start,slot.ends_at,a.id)+1; attention:=predicted>cfg.simultaneous_capacity;
  update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,staff_id=slot.staff_id,room_id=null,
   status=case when attention or not cfg.auto_confirm then 'pending' else 'confirmed' end,capacity_attention_required=attention,capacity_count_snapshot=predicted,capacity_limit_snapshot=cfg.simultaneous_capacity
  where id=a.id returning * into a;
  perform spa_private.audit('booking.customer_rescheduled',a.id::text,jsonb_build_object('old_start',old_start,'new_start',p_start,'reason',p_reason,'capacity_count',predicted,'capacity_limit',cfg.simultaneous_capacity,'capacity_attention_required',attention));
 end if;
 result:=spa_private.booking_summary(a); insert into public.spa_booking_actions values(p_request,a.customer_id,a.id,payload,result,now()); return result;
end $$;

create or replace function public.spa_reschedule(p_id uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; slot record; cfg public.spa_settings; predicted int; attention boolean;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed') or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'INVALID_TRANSITION'; end if;
 if not exists(select 1 from public.spa_reschedule_availability(a.id,p_date,p_staff) av where av.starts_at=p_start and av.available) then raise exception 'SLOT_TAKEN'; end if;
 select * into slot from spa_private.reschedule_candidates(a.id,p_date,p_start,p_staff,false) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 select * into cfg from public.spa_settings; predicted:=spa_private.capacity_peak(p_start,slot.ends_at,a.id)+1; attention:=predicted>cfg.simultaneous_capacity;
 update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,
  staff_id=slot.staff_id,staff_name_snapshot=(select name from public.spa_staff where id=slot.staff_id),room_id=null,
  status=case when attention then 'pending' else a.status end,capacity_attention_required=attention,capacity_count_snapshot=predicted,capacity_limit_snapshot=cfg.simultaneous_capacity where id=p_id;
 perform spa_private.audit('booking.rescheduled',p_id::text,jsonb_build_object('old_start',a.starts_at,'new_start',p_start,'previous_staff_id',a.staff_id,'assigned_staff_id',slot.staff_id,'reason',p_reason,'capacity_count',predicted,'capacity_limit',cfg.simultaneous_capacity,'capacity_attention_required',attention));
end $$;

create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare can_manage boolean:=spa_private.has_permission('appointments.manage'); capacity int:=(select simultaneous_capacity from public.spa_settings limit 1);
begin
 perform spa_private.require_permission('appointments.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(
  (case when can_manage then to_jsonb(a)-'room_id' else jsonb_build_object('id',a.id,'reference',a.reference,'staff_id',a.staff_id,'service_id',a.service_id,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'service_name',a.service_name_snapshot,'capacity_attention_required',a.capacity_attention_required,'capacity_count_snapshot',a.capacity_count_snapshot,'capacity_limit_snapshot',a.capacity_limit_snapshot) end)
  ||jsonb_build_object('customer_name',case when can_manage then c.name else left(btrim(c.name),1)||'客人' end,'phone',case when can_manage then c.phone else null end,'therapist',s.name,
   'capacity_exceeded',spa_private.capacity_exceeded(a.id),'capacity_current_count',spa_private.capacity_peak(a.starts_at,a.ends_at,null),'capacity_limit',capacity,
   'original_staff_id',coalesce(first_change.previous_staff_id,a.staff_id),'original_therapist',coalesce(original_staff.name,s.name),'staff_change_count',(select count(*) from public.spa_appointment_staff_changes x where x.appointment_id=a.id),
   'last_reassignment_reason',case when can_manage then (select x.reason from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at desc limit 1) end,
   'checkout',case when spa_private.has_permission('finance.view') then to_jsonb(ch) else null end) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id
  left join public.spa_checkouts ch on ch.appointment_id=a.id
  left join lateral (select x.previous_staff_id from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at limit 1) first_change on true
  left join public.spa_staff original_staff on original_staff.id=first_change.previous_staff_id
  where a.business_date between p_from and p_to),'[]');
end $$;

create or replace function public.spa_monthly_operations(p_month date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare month_start date:=date_trunc('month',p_month)::date; month_end date; work_date date; day_start timestamptz; day_end timestamptz; hours jsonb; shifts jsonb; rests jsonb; leaves jsonb; appointments jsonb; days jsonb:='[]'::jsonb; can_manage boolean:=spa_private.has_permission('appointments.manage'); viewer uuid:=spa_private.current_staff_id(); capacity int:=(select simultaneous_capacity from public.spa_settings limit 1); peak int;
begin
 perform spa_private.require_permission('dashboard.view'); if p_month is null then raise exception 'INVALID_DATE'; end if; month_end:=(month_start+interval '1 month - 1 day')::date;
 for work_date in select generate_series(month_start,month_end,interval '1 day')::date loop
  day_start:=work_date::timestamp at time zone 'Asia/Taipei'; day_end:=(work_date+1)::timestamp at time zone 'Asia/Taipei'; select to_jsonb(w) into hours from spa_private.business_window(work_date) w;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'start_minute',roster.start_minute,'end_minute',roster.end_minute,'source',roster.source,'note',roster.note,'is_own',s.id=viewer) order by roster.start_minute,s.display_order,s.name),'[]'::jsonb) into shifts from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id cross join lateral spa_private.staff_shift_window(s.id,work_date) roster where s.active and s.employment_status='active' and s.archived_at is null and roster.is_working;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'source',roster.source,'note',roster.note,'is_own',s.id=viewer) order by s.display_order,s.name),'[]'::jsonb) into rests from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id cross join lateral spa_private.staff_shift_window(s.id,work_date) roster where s.active and s.employment_status='active' and s.archived_at is null and not roster.is_working;
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'starts_at',o.starts_at,'ends_at',o.ends_at,'reason',o.reason,'is_own',s.id=viewer) order by o.starts_at,s.display_order,s.name),'[]'::jsonb) into leaves from public.spa_time_off o join public.spa_staff s on s.id=o.staff_id left join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and o.starts_at<day_end and o.ends_at>day_start;
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'reference',a.reference,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'customer_name',case when can_manage then c.name else left(btrim(c.name),1)||'小姐' end,'service_name',coalesce(a.service_name_snapshot,a.service_name),'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'capacity_exceeded',spa_private.capacity_exceeded(a.id),'capacity_current_count',spa_private.capacity_peak(a.starts_at,a.ends_at,null),'capacity_limit',capacity,'is_own',s.id=viewer) order by a.starts_at,s.display_order),'[]'::jsonb) into appointments from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id left join public.spa_job_titles j on j.id=s.job_title_id where a.business_date=work_date and a.status not in ('cancelled','no_show');
  select coalesce(max((select count(*) from public.spa_appointments active
   where active.business_date=work_date and active.status not in ('cancelled','no_show')
    and active.starts_at<=marker.starts_at and active.ends_at>marker.starts_at)),0) into peak
  from public.spa_appointments marker where marker.business_date=work_date and marker.status not in ('cancelled','no_show');
  days:=days||jsonb_build_array(jsonb_build_object('date',work_date,'store_hours',coalesce(hours,'{}'::jsonb),'shift_count',jsonb_array_length(shifts),'off_count',(select count(distinct staff_id) from (select (x->>'staff_id')::uuid staff_id from jsonb_array_elements(rests) x union all select (x->>'staff_id')::uuid from jsonb_array_elements(leaves) x) off_people),'appointment_count',jsonb_array_length(appointments),'peak_simultaneous_count',peak,'capacity_attention_count',(select count(*) from jsonb_array_elements(appointments) x where coalesce((x->>'capacity_exceeded')::boolean,false)),'shifts',shifts,'rests',rests,'leaves',leaves,'appointments',appointments));
 end loop;
 return jsonb_build_object('month',to_char(month_start,'YYYY-MM'),'from',month_start,'to',month_end,'active_staff_count',(select count(*) from public.spa_staff where active and employment_status='active' and archived_at is null),'simultaneous_capacity',capacity,'viewer_staff_id',viewer,'can_manage_appointments',can_manage,'days',days);
end $$;

create or replace function public.spa_dashboard() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; owner_view boolean:=spa_private.role_name()='owner'; can_manage boolean:=spa_private.has_permission('appointments.manage'); capacity int:=(select simultaneous_capacity from public.spa_settings limit 1);
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object('date',today,'appointments',(select count(*) from public.spa_appointments where business_date=today),'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',case when owner_view then coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.business_date=today and ch.refunded_at is null),0) end,
  'staff_working',(select count(*) from public.spa_staff s join lateral spa_private.staff_shift_window(s.id,today) roster on roster.is_working where s.active and s.employment_status='active' and s.archived_at is null),
  'simultaneous_capacity',capacity,'capacity_attention_count',(select count(*) from public.spa_appointments a where a.business_date=today and spa_private.capacity_exceeded(a.id)),
  'new_members',case when owner_view then (select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today) end,
  'low_stock',case when owner_view then (select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold) end,
  'today_hours',(select to_jsonb(w) from spa_private.business_window(today) w),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,case when can_manage then c.name else left(btrim(c.name),1)||'小姐' end customer_name,s.name staff_name,spa_private.capacity_exceeded(a.id) capacity_exceeded from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

create or replace function public.spa_settings_os() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 return jsonb_build_object('business',coalesce((select value from public.spa_business_settings where key='business'),'{}'),'website',coalesce((select value from public.spa_business_settings where key='website'),'{}'),'inventory',coalesce((select value from public.spa_business_settings where key='inventory'),'{}'),'assignment',coalesce((select value from public.spa_business_settings where key='assignment'),'{}'),'booking',(select to_jsonb(s) from public.spa_settings s),
  'business_hours',coalesce((select jsonb_agg(to_jsonb(h) order by weekday) from public.spa_business_hours h),'[]'),
  'business_overrides',coalesce((select jsonb_agg(to_jsonb(o) order by business_date) from public.spa_business_day_overrides o where business_date>=(now() at time zone 'Asia/Taipei')::date and business_date<(now() at time zone 'Asia/Taipei')::date+180),'[]'));
end $$;

create or replace function public.spa_booking_capacity_save(p_capacity int) returns void
language plpgsql security definer set search_path='' as $$
declare old_value int;
begin
 perform spa_private.require_permission('settings.manage');
 if p_capacity is null or p_capacity not between 1 and 20 then raise exception 'INVALID_INPUT'; end if;
 select simultaneous_capacity into old_value from public.spa_settings for update;
 update public.spa_settings set simultaneous_capacity=p_capacity;
 perform spa_private.audit('booking.capacity_saved','settings',jsonb_build_object('old_capacity',old_value,'simultaneous_capacity',p_capacity));
end $$;

create or replace function spa_private.operations_task_revision(p_key text,p_context jsonb,p_viewer uuid) returns text
language plpgsql stable security definer set search_path='' as $$
declare result text; first_day date:=(p_context->>'from')::date; last_day date:=(p_context->>'to')::date;
begin
 if p_key in ('capacity_attention','pending_bookings','arrivals','completion','unsettled','my_schedule') then
  select md5(coalesce(string_agg(a.id::text||a.staff_id::text||a.starts_at::text||a.ends_at::text||a.status||a.capacity_attention_required::text,'|' order by a.id),'')) into result
  from public.spa_appointments a where a.business_date between first_day and last_day
   and (not(p_context?'status') or a.status=p_context->>'status')
   and (not(p_context?'statuses') or (p_context->'statuses')?a.status)
   and (not(p_context?'staff_id') or a.staff_id=(p_context->>'staff_id')::uuid)
   and (not(p_context?'starts_before') or a.starts_at<=(p_context->>'starts_before')::timestamptz)
   and (not(p_context?'ends_before') or a.ends_at<=(p_context->>'ends_before')::timestamptz)
   and (not(p_context?'blocked_after') or a.blocked_until>(p_context->>'blocked_after')::timestamptz)
   and (not coalesce((p_context->>'capacity_attention')::boolean,false) or spa_private.capacity_exceeded(a.id))
   and (not coalesce((p_context->>'exclude_capacity_attention')::boolean,false) or not spa_private.capacity_exceeded(a.id))
   and (not coalesce((p_context->>'unsettled')::boolean,false) or not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id));
 elsif p_key in ('attendance','my_attendance','missing_clockout','my_clockout') then
  select md5(coalesce(string_agg(a.id::text||a.version::text,'|' order by a.id),'')) into result from public.spa_attendance a cross join public.spa_attendance_settings cfg
  where (p_key='my_clockout' or a.work_date between first_day and last_day) and a.status=case when p_key in ('missing_clockout','my_clockout') then 'open' else 'pending' end
   and (p_key not in ('my_attendance','my_clockout') or a.staff_id=p_viewer) and (p_key<>'missing_clockout' or a.clock_in<=now()-make_interval(mins=>cfg.max_shift_minutes));
 elsif p_key='corrections' then select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_attendance_requests where status='pending' and work_date between first_day and last_day;
 elsif p_key in ('schedule_requests','my_requests') then select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_staff_schedule_change_requests where status='pending' and business_date between first_day and last_day and (p_key<>'my_requests' or staff_id=p_viewer) and (not(p_context?'requested_since') or requested_at>(p_context->>'requested_since')::timestamptz);
 elsif p_key='missing_schedule' then select md5(coalesce(string_agg(s.id::text,'|' order by s.id),'')) into result from public.spa_staff s where s.active and s.employment_status='active' and s.archived_at is null and exists(select 1 from public.spa_roles r join public.spa_role_profiles p on p.code=r.role where r.staff_id=s.id and r.active and r.role<>'owner' and p.active and p.archived_at is null) and not exists(select 1 from public.spa_staff_schedule_submissions q where q.staff_id=s.id and q.schedule_month=(p_context->>'target_month')::date);
 elsif p_key='my_submission' then result:=md5(p_viewer::text||coalesce(p_context->>'target_month',''));
 elsif p_key='payroll_drafts' then select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_payroll_runs where status='draft' and needs_recalculation and period_end>=first_day and period_start<=last_day;
 elsif p_key='low_stock' then select md5(coalesce(string_agg(p.id::text||stock.n::text,'|' order by p.id),'')) into result from public.spa_products p cross join lateral (select coalesce(sum(i.delta),0) n from public.spa_inventory_entries i where i.product_id=p.id) stock where p.status='active' and stock.n<=p.low_stock_threshold;
 elsif p_key='reviews' then select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_reviews where status='pending' and (created_at at time zone 'Asia/Taipei')::date between first_day and last_day;
 end if;
 return coalesce(result,md5(''));
end $$;

create or replace function public.spa_operations_convenience() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare instant timestamptz:=now(); today date:=(now() at time zone 'Asia/Taipei')::date; first_date date:=today-90; last_date date:=spa_private.public_booking_last_date(); target_month date:=(date_trunc('month',today)+interval '1 month')::date; owner_view boolean:=spa_private.role_name()='owner'; viewer uuid:=spa_private.current_staff_id(); todos jsonb:='[]'::jsonb; total bigint; task jsonb; next_refresh timestamptz; revised jsonb:='[]'::jsonb; own_open boolean; edit_open boolean:=extract(day from today)::int<=7; capacity int:=(select simultaneous_capacity from public.spa_settings limit 1); current_guests int;
begin
 perform spa_private.require_permission('dashboard.view');
 select count(*) into current_guests from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service') and a.starts_at<=instant and a.ends_at>instant;
 if owner_view then
  select count(*) into total from public.spa_appointments a where a.status='pending' and a.business_date between first_date and last_date and spa_private.capacity_exceeded(a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','capacity_attention','title','超出建議容量待聯絡','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',last_date,'status','pending','capacity_attention',true),'description','預約已保留；請致電顧客協調時段，確認安排後再更新狀態。'));
  select count(*) into total from public.spa_appointments a where a.status='pending' and a.business_date between first_date and last_date and not spa_private.capacity_exceeded(a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','pending_bookings','title','預約待確認','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',last_date,'status','pending','exclude_capacity_attention',true),'description','核對技師、時段與顧客預約。'));
  select count(*) into total from public.spa_appointments where status='confirmed' and starts_at<=instant+interval '30 minutes' and business_date between first_date and today+1;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','arrivals','title','即將到店／逾時未到','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today+1,'status','confirmed','starts_before',instant+interval '30 minutes'),'description','已確認且即將開始或已逾時，尚未標記到店；請核對實際狀況。'));
  select count(*) into total from public.spa_appointments where status in ('checked_in','in_service') and ends_at<=instant and business_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','completion','title','療程結束待核對','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today,'statuses',jsonb_build_array('checked_in','in_service'),'ends_before',instant),'description','排定時間已結束，尚未確認完成；請核對實際技師。'));
  select count(*) into total from public.spa_appointments a where status='completed' and business_date between first_date and today and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','unsettled','title','已完成待結帳','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today,'status','completed','unsettled',true),'description','完成服務需結帳後才會計入薪資提成。'));
  select count(*) into total from public.spa_attendance where status='pending' and work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','attendance','title','出勤待審核','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','核准後才會寫入計薪工時。'));
  select count(*) into total from public.spa_attendance_requests where status='pending' and work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','corrections','title','補打卡／工時更正申請','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','核對申請原因與時間後審核。'));
  select count(*) into total from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open' and a.clock_in<=instant-make_interval(mins=>cfg.max_shift_minutes) and a.work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','missing_clockout','title','長時間未打下班卡','count',total,'severity','urgent','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','已超過門店最長班次設定，請核對是否漏打卡。'));
  select count(*) into total from public.spa_staff_schedule_change_requests where status='pending' and requested_at>instant-interval '90 days' and business_date between first_date and last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','schedule_requests','title','班表更動待確認','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',last_date,'section','schedule-review','status','pending','requested_since',instant-interval '90 days'),'description','核准會套用正式班表，並同步預約可用時段。'));
  select count(*) into total from public.spa_staff s where s.active and s.employment_status='active' and s.archived_at is null and exists(select 1 from public.spa_roles r join public.spa_role_profiles p on p.code=r.role where r.staff_id=s.id and r.active and r.role<>'owner' and p.active and p.archived_at is null) and not exists(select 1 from public.spa_staff_schedule_submissions q where q.staff_id=s.id and q.schedule_month=target_month);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','missing_schedule','title','下月班表尚未提交','count',total,'severity',case when edit_open then 'normal' else 'urgent' end,'module','team','context',jsonb_build_object('from',target_month,'to',last_date,'section','schedule-review','target_month',target_month,'missing_submission',true),'description',case when edit_open then '員工可於本月 7 日前完成下月排班。' else '員工填班已鎖定；未交者沿用每週班表，請由店主核對。' end));
  select count(*) into total from public.spa_payroll_runs where status='draft' and needs_recalculation and period_end>=first_date and period_start<=last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','payroll_drafts','title','薪資草稿需要重算','count',total,'severity','normal','module','payroll','context',jsonb_build_object('from',first_date,'to',last_date,'section','history','status','draft','needs_recalculation',true),'description','工時、服務或制度已有更新，請在結算紀錄選取原週期重新試算。'));
  select count(*) into total from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','low_stock','title','商品低庫存','count',total,'severity','normal','module','catalog','context',jsonb_build_object('section','products'),'description','核對實際庫存，補貨後登錄庫存調整。'));
  select count(*) into total from public.spa_reviews where status='pending' and (created_at at time zone 'Asia/Taipei')::date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','reviews','title','顧客評價待審核','count',total,'severity','normal','module','reviews','context',jsonb_build_object('from',first_date,'to',today,'status','pending'),'description','審核公開內容或回覆顧客體驗。'));
 elsif viewer is not null then
  select count(*) into total from public.spa_appointments where staff_id=viewer and status in ('pending','confirmed','checked_in','in_service') and business_date between today-1 and today+1 and starts_at<=instant+interval '2 hours' and blocked_until>instant;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','my_schedule','title','我的近期服務排程','count',total,'severity','normal','module','bookings','context',jsonb_build_object('from',today-1,'to',today+1,'staff_id',viewer,'statuses',jsonb_build_array('pending','confirmed','checked_in','in_service'),'starts_before',instant+interval '2 hours','blocked_after',instant),'description','查看實際安排給您的療程；預約狀態由店主確認。'));
  select exists(select 1 from public.spa_attendance where staff_id=viewer and status='open') into own_open;
  if own_open then todos:=todos||jsonb_build_array(jsonb_build_object('key','my_clockout','title','目前上班中','count',1,'severity','normal','module','self','context',jsonb_build_object('from',today-1,'to',today,'section','my-attendance'),'description','下班時請到出勤打卡取得定位並打下班卡。')); end if;
  select count(*) into total from public.spa_attendance where staff_id=viewer and status='pending' and work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','my_attendance','title','我的出勤待審核','count',total,'severity','waiting','module','self','context',jsonb_build_object('from',first_date,'to',today,'section','my-attendance'),'description','等待店主核准後計入工時，可查看審核狀態。'));
  select count(*) into total from public.spa_staff_schedule_change_requests where staff_id=viewer and status='pending' and business_date between greatest(first_date,today-30) and last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','my_requests','title','我的班表更動待確認','count',total,'severity','waiting','module','self','context',jsonb_build_object('from',greatest(first_date,today-30),'to',last_date,'section','my-schedule','status','pending'),'description','申請尚未核准時，正式班表保持原設定。'));
  if not exists(select 1 from public.spa_staff_schedule_submissions where staff_id=viewer and schedule_month=target_month) then todos:=todos||jsonb_build_array(jsonb_build_object('key','my_submission','title','下月班表尚未提交','count',1,'severity',case when edit_open then 'normal' else 'waiting' end,'module','self','context',jsonb_build_object('from',target_month,'to',last_date,'section','my-schedule','target_month',target_month),'description',case when edit_open then '請於本月 7 日前完成修改並提交下月班表。' else '自助填班已鎖定；請聯絡店主核對，或提出更動申請。' end)); end if;
 end if;
 for task in select value from jsonb_array_elements(todos) loop revised:=revised||jsonb_build_array(task||jsonb_build_object('revision',spa_private.operations_task_revision(task->>'key',task->'context',viewer))); end loop;
 select min(boundary) into next_refresh from (select ((today+1)::timestamp at time zone 'Asia/Taipei') boundary union all select point from public.spa_appointments a cross join lateral unnest(array[a.starts_at-interval '48 hours',a.starts_at-interval '2 hours',a.starts_at-interval '30 minutes',a.starts_at,a.ends_at,a.blocked_until]) point where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.business_date between today-1 and last_date union all select a.clock_in+make_interval(mins=>cfg.max_shift_minutes) from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open') future where boundary>instant;
 return jsonb_build_object('next_refresh_at',next_refresh,'server_time',instant,'today',today,'window',jsonb_build_object('from',first_date,'to',last_date),'target_month',target_month,'edit_open',edit_open,'is_owner',owner_view,'capacity',jsonb_build_object('limit',capacity,'current_guests',current_guests,'currently_exceeded',current_guests>capacity,'pending_attention_count',(select count(*) from public.spa_appointments a where a.status='pending' and a.business_date between first_date and last_date and spa_private.capacity_exceeded(a.id))),'todos',revised);
end $$;

revoke all on function public.spa_booking_capacity_save(int) from public,anon,authenticated;
grant execute on function public.spa_booking_capacity_save(int) to authenticated,service_role;
revoke execute on function public.spa_room_save(uuid,text,boolean) from authenticated;

notify pgrst,'reload schema';
commit;
