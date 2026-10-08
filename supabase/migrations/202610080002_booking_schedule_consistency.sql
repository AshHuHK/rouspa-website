begin;

-- Managers must be able to manage every date currently bookable by customers.
create or replace function spa_private.booking_last_date()
returns date language sql stable security definer set search_path='' as $$
 select case when spa_private.has_permission('appointments.manage')
  then greatest((now() at time zone s.timezone)::date+s.booking_days,spa_private.public_booking_last_date())
  else spa_private.public_booking_last_date() end from public.spa_settings s
$$;

-- A new employee without a weekly template starts on rest days, but still has
-- valid default times when they switch a draft day to working.
create or replace function spa_private.staff_shift_window(p_staff uuid,p_date date)
returns table(is_working boolean,start_minute int,end_minute int,source text,note text)
language sql stable security definer set search_path='' as $$
 select coalesce(d.is_working,w.staff_id is not null),coalesce(d.start_minute,w.start_minute,cfg.opening_minute),coalesce(d.end_minute,w.end_minute,cfg.closing_minute),
  case when d.id is not null then 'daily' when w.staff_id is not null then 'weekly' else 'none' end,coalesce(d.note,'')
 from public.spa_settings cfg
 left join public.spa_daily_shifts d on d.staff_id=p_staff and d.business_date=p_date
 left join public.spa_shifts w on w.staff_id=p_staff and w.weekday=extract(dow from p_date)::int
$$;

-- All allocation inputs use the booking lock, including privileged table writes.
-- Validate the effective window after the write so deleting a daily override is
-- checked against the weekly template it restores.
create or replace function spa_private.allocation_write_lock() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(726001);
 return coalesce(new,old);
end $$;

create or replace function spa_private.check_staff_booking_window(p_staff uuid,p_date date)
returns void language plpgsql security definer set search_path='' as $$
declare roster record; cfg public.spa_settings;
begin
 select * into cfg from public.spa_settings;
 select * into roster from spa_private.staff_shift_window(p_staff,p_date);
 if exists(select 1 from public.spa_appointments a where a.staff_id=p_staff and a.business_date=p_date
  and a.status in ('pending','confirmed','checked_in','in_service')
  and (not coalesce(roster.is_working,false)
   or a.starts_at<((p_date::timestamp+make_interval(mins=>roster.start_minute)) at time zone cfg.timezone)
   or a.blocked_until>((p_date::timestamp+make_interval(mins=>roster.end_minute)) at time zone cfg.timezone)))
 then raise exception 'EXISTING_BOOKINGS'; end if;
end $$;

create or replace function spa_private.roster_booking_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare day date;
begin
 if tg_table_name='spa_daily_shifts' then
  if tg_op<>'INSERT' then perform spa_private.check_staff_booking_window(old.staff_id,old.business_date); end if;
  if tg_op<>'DELETE' then perform spa_private.check_staff_booking_window(new.staff_id,new.business_date); end if;
 else
  if tg_op<>'INSERT' then
   for day in select distinct a.business_date from public.spa_appointments a
    where a.staff_id=old.staff_id and extract(dow from a.business_date)::int=old.weekday
     and a.status in ('pending','confirmed','checked_in','in_service')
   loop perform spa_private.check_staff_booking_window(old.staff_id,day); end loop;
  end if;
  if tg_op<>'DELETE' then
   for day in select distinct a.business_date from public.spa_appointments a
    where a.staff_id=new.staff_id and extract(dow from a.business_date)::int=new.weekday
     and a.status in ('pending','confirmed','checked_in','in_service')
   loop perform spa_private.check_staff_booking_window(new.staff_id,day); end loop;
  end if;
 end if;
 return coalesce(new,old);
end $$;

create or replace function spa_private.leave_booking_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.spa_appointments a where a.staff_id=new.staff_id
  and a.status in ('pending','confirmed','checked_in','in_service')
  and a.starts_at<new.ends_at and a.blocked_until>new.starts_at)
 then raise exception 'EXISTING_BOOKINGS'; end if;
 return new;
end $$;

create or replace function spa_private.check_store_booking_window(p_date date)
returns void language plpgsql security definer set search_path='' as $$
declare hours record; cfg public.spa_settings;
begin
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if exists(select 1 from public.spa_appointments a where a.business_date=p_date
  and a.status in ('pending','confirmed','checked_in','in_service')
  and (not coalesce(hours.is_open,false)
   or a.starts_at<((p_date::timestamp+make_interval(mins=>hours.opening_minute)) at time zone cfg.timezone)
   or a.blocked_until>((p_date::timestamp+make_interval(mins=>hours.closing_minute)) at time zone cfg.timezone)))
 then raise exception 'EXISTING_BOOKINGS'; end if;
end $$;

create or replace function spa_private.store_booking_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare day date;
begin
 if tg_table_name='spa_business_day_overrides' then
  if tg_op<>'INSERT' then perform spa_private.check_store_booking_window(old.business_date); end if;
  if tg_op<>'DELETE' then perform spa_private.check_store_booking_window(new.business_date); end if;
 else
  for day in select distinct a.business_date from public.spa_appointments a
   where a.status in ('pending','confirmed','checked_in','in_service')
    and ((tg_op<>'INSERT' and extract(dow from a.business_date)::int=old.weekday)
      or (tg_op<>'DELETE' and extract(dow from a.business_date)::int=new.weekday))
  loop perform spa_private.check_store_booking_window(day); end loop;
 end if;
 return coalesce(new,old);
end $$;

do $$ declare table_name text; begin
 foreach table_name in array array['spa_shifts','spa_daily_shifts','spa_time_off','spa_business_hours','spa_business_day_overrides'] loop
  execute format('drop trigger if exists spa_allocation_write_lock on public.%I',table_name);
  execute format('create trigger spa_allocation_write_lock before insert or update or delete on public.%I for each row execute function spa_private.allocation_write_lock()',table_name);
 end loop;
 foreach table_name in array array['spa_shifts','spa_daily_shifts'] loop
  execute format('drop trigger if exists spa_roster_booking_guard on public.%I',table_name);
  execute format('create trigger spa_roster_booking_guard after insert or update or delete on public.%I for each row execute function spa_private.roster_booking_guard()',table_name);
 end loop;
 foreach table_name in array array['spa_business_hours','spa_business_day_overrides'] loop
  execute format('drop trigger if exists spa_store_booking_guard on public.%I',table_name);
  execute format('create trigger spa_store_booking_guard after insert or update or delete on public.%I for each row execute function spa_private.store_booking_guard()',table_name);
 end loop;
end $$;
drop trigger if exists spa_leave_booking_guard on public.spa_time_off;
create trigger spa_leave_booking_guard before insert or update on public.spa_time_off
for each row execute function spa_private.leave_booking_guard();

create or replace function spa_private.guard_appointment() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(726001);
 if new.status in ('pending','confirmed','checked_in','in_service','completed') then
  if exists(select 1 from public.spa_appointments a where a.id<>new.id
   and a.status in ('pending','confirmed','checked_in','in_service','completed')
   and (a.staff_id=new.staff_id or a.room_id=new.room_id)
   and a.starts_at<new.blocked_until and a.blocked_until>new.starts_at)
  then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 end if;
 new.updated_at=now(); return new;
end $$;

-- The number shown on public slots is simultaneous capacity, capped by beds.
create or replace function spa_private.available_staff_count(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns int language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings), hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s),
 rooms as (select count(*)::int capacity from public.spa_rooms r cross join timing t where r.active
  and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed')
   and a.room_id=r.id and a.starts_at<t.blocked and a.blocked_until>p_start)),
 staff as (select count(distinct st.id)::int capacity from public.spa_staff st
  join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
  join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
  cross join cfg cross join hours h cross join timing t
  where h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable
   and (p_staff is null or st.id=p_staff)
   and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
   and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
   and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
   and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed')
    and a.staff_id=st.id and a.starts_at<t.blocked and a.blocked_until>p_start))
 select least(rooms.capacity,staff.capacity) from rooms cross join staff
$$;

create or replace function public.spa_public_available_staff(p_service uuid,p_date date,p_start timestamptz)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; minute int;
begin
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if p_date is null or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.public_booking_last_date() then raise exception 'INVALID_DATE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_start is null or not coalesce(hours.is_open,false) or p_start<=now()+interval '30 minutes'
  or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0
  or date_trunc('minute',p_start)<>p_start then return '[]'::jsonb; end if;
 return coalesce((select jsonb_agg(to_jsonb(x)-'workload_minutes'-'display_order' order by x.workload_minutes,x.display_order,x.name) from (
  select distinct st.id,st.name,st.name_en,coalesce(j.name,st.title) title,coalesce(j.name_en,'') title_en,st.specialty,st.display_order,
   coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),0)::int workload_minutes
  from spa_private.candidates(p_service,p_date,p_start,null) c join public.spa_staff st on st.id=c.staff_id left join public.spa_job_titles j on j.id=st.job_title_id
 ) x),'[]'::jsonb);
end $$;

-- Rescheduling keeps the originally purchased duration and cleanup snapshot.
-- Owners may honor an existing booking after the catalog item is taken offline.
create or replace function spa_private.reschedule_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid,p_require_public boolean default true)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select st.id,r.id,p_start+(a.ends_at-a.starts_at),p_start+(a.blocked_until-a.starts_at)
 from public.spa_appointments a join public.spa_services svc on svc.id=a.service_id
 cross join public.spa_settings cfg cross join spa_private.business_window(p_date) h cross join public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=a.service_id and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working cross join public.spa_rooms r
 where a.id=p_id and (not p_require_public or (svc.active and svc.status='active' and svc.online_booking_enabled))
  and h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable and r.active
  and (p_staff is null or st.id=p_staff)
  and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
  and p_start+(a.blocked_until-a.starts_at)<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
  and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<p_start+(a.blocked_until-a.starts_at) and o.ends_at>p_start)
  and not exists(select 1 from public.spa_appointments other where other.id<>a.id
   and other.status in ('pending','confirmed','checked_in','in_service','completed')
   and (other.staff_id=st.id or other.room_id=r.id) and other.starts_at<p_start+(a.blocked_until-a.starts_at) and other.blocked_until>p_start)
 order by coalesce((select sum(b.duration_minutes_snapshot) from public.spa_appointments b where b.staff_id=st.id and b.business_date=p_date and b.id<>a.id and b.status not in ('cancelled','no_show')),0),st.display_order,r.name
$$;

create or replace function spa_private.customer_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select * from spa_private.reschedule_candidates(p_id,p_date,p_start,p_staff,true)
$$;

create or replace function public.spa_reschedule_availability(p_id uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available boolean)
language plpgsql stable security definer set search_path='' as $$
declare a public.spa_appointments; cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 perform spa_private.require_permission('appointments.manage');
 select * into a from public.spa_appointments where id=p_id;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed') then raise exception 'INVALID_TRANSITION'; end if;
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.booking_last_date() then return; end if;
 for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI'); starts_at:=start_at;
  available:=start_at>now()+interval '30 minutes' and exists(select 1 from spa_private.reschedule_candidates(a.id,p_date,start_at,p_staff,false)); return next;
 end loop;
end $$;

create or replace function public.spa_reschedule(p_id uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; slot record;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed') or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'INVALID_TRANSITION'; end if;
 if not exists(select 1 from public.spa_reschedule_availability(a.id,p_date,p_staff) av where av.starts_at=p_start and av.available) then raise exception 'SLOT_TAKEN'; end if;
 select * into slot from spa_private.reschedule_candidates(a.id,p_date,p_start,p_staff,false) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,
  staff_id=slot.staff_id,staff_name_snapshot=(select name from public.spa_staff where id=slot.staff_id),room_id=slot.room_id where id=p_id;
 perform spa_private.audit('booking.rescheduled',p_id::text,jsonb_build_object('old_start',a.starts_at,'new_start',p_start,'previous_staff_id',a.staff_id,'assigned_staff_id',slot.staff_id,'reason',p_reason));
end $$;

create or replace function public.spa_staff_schedule_submit(p_month date,p_days jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.current_staff_id(); today date:=(now() at time zone 'Asia/Taipei')::date; target date:=(date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '1 month')::date; final_date date; expected int; item jsonb; work_date date; working boolean; start_min int; end_min int; maximum int;
begin
 perform spa_private.require_team(); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726101);
 if person is null then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if extract(day from today)::int not between 1 and 7 then raise exception 'SCHEDULE_LOCKED'; end if;
 if p_month is null or date_trunc('month',p_month)::date<>target or p_days is null or jsonb_typeof(p_days)<>'array' then raise exception 'INVALID_SCHEDULE'; end if;
 final_date:=(target+interval '1 month - 1 day')::date; expected:=final_date-target+1;
 if jsonb_array_length(p_days)<>expected or (select count(distinct x->>'date') from jsonb_array_elements(p_days) x)<>expected
  or exists(select 1 from jsonb_array_elements(p_days) x where x->>'date' is null or (x->>'date')::date not between target and final_date) then raise exception 'INVALID_SCHEDULE'; end if;
 select max_staff_off_per_day into maximum from public.spa_settings;
 for item in select * from jsonb_array_elements(p_days) loop
  work_date:=(item->>'date')::date; working:=(item->>'is_working')::boolean; start_min:=(item->>'start_minute')::int; end_min:=(item->>'end_minute')::int;
  if working is null or start_min is null or end_min is null or start_min<0 or end_min<=start_min or end_min>2880 then raise exception 'INVALID_SCHEDULE'; end if;
  -- Existing owner-approved rest days remain resubmittable even if an owner
  -- subsequently overrode the daily cap for another colleague.
  if not working and (select sw.is_working from spa_private.staff_shift_window(person,work_date) sw)
   and (select count(*) from public.spa_staff st join lateral spa_private.staff_shift_window(st.id,work_date) sw on not sw.is_working
    where st.id<>person and st.active and st.employment_status='active' and st.archived_at is null)>=maximum then raise exception 'OFF_LIMIT'; end if;
  insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
  values(person,work_date,working,start_min,end_min,'員工月班表',auth.uid(),now())
  on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 end loop;
 insert into public.spa_staff_schedule_submissions(staff_id,schedule_month,submitted_by)
 values(person,target,auth.uid()) on conflict(staff_id,schedule_month) do update set version=spa_staff_schedule_submissions.version+1,submitted_at=now(),submitted_by=auth.uid();
 perform spa_private.audit('schedule.employee_submitted',person::text,jsonb_build_object('month',target,'days',expected));
 return (select to_jsonb(s) from public.spa_staff_schedule_submissions s where s.staff_id=person and s.schedule_month=target);
end $$;

create or replace function public.spa_staff_schedule_request_review(p_id uuid,p_approve boolean,p_note text default '')
returns void language plpgsql security definer set search_path='' as $$
declare request public.spa_staff_schedule_change_requests; shift_id uuid;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726101);
 if p_approve is null or length(coalesce(p_note,''))>1000 then raise exception 'INVALID_INPUT'; end if;
 select * into request from public.spa_staff_schedule_change_requests where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if request.status<>'pending' then raise exception 'INVALID_TRANSITION'; end if;
 if p_approve then
  if request.business_date<(now() at time zone 'Asia/Taipei')::date then raise exception 'INVALID_DATE'; end if;
  if not exists(select 1 from public.spa_staff s where s.id=request.staff_id and s.active and s.employment_status='active' and s.archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
  insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
  values(request.staff_id,request.business_date,request.desired_working,request.desired_start_minute,request.desired_end_minute,left('核准員工變更：'||request.reason,500),auth.uid(),now())
  on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at returning id into shift_id;
 end if;
 update public.spa_staff_schedule_change_requests set status=case when p_approve then 'approved' else 'rejected' end,
  reviewed_by=auth.uid(),reviewed_at=now(),review_note=btrim(coalesce(p_note,'')),applied_shift_id=shift_id where id=p_id;
 perform spa_private.audit('schedule.change_reviewed',p_id::text,jsonb_build_object('approved',p_approve,'note',p_note));
end $$;

-- A public booking is not a profile-edit API. Keep the name/phone identity used
-- by member lookup intact, and require the owner to restore disabled profiles.
create or replace function public.spa_create_booking(p_request uuid,p_service uuid,p_date date,p_start timestamptz,p_staff uuid,p_name text,p_phone text,p_tea int default 0,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; svc public.spa_services; slot record; customer public.spa_customers; booking public.spa_appointments; tel text; minute int; assigned_name text;
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
  return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference);
 end if;
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 select * into svc from public.spa_services where id=p_service and active and status='active' and online_booking_enabled;
 if not found then raise exception 'INVALID_SERVICE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.booking_last_date() or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 if customer.id is not null and (select count(*) from public.spa_appointments where customer_id=customer.id and created_at>now()-interval '24 hours')>=5 then raise exception 'RATE_LIMIT'; end if;
 select * into slot from spa_private.candidates(p_service,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 if customer.id is null then insert into public.spa_customers(name,phone) values(btrim(p_name),tel) returning * into customer; end if;
 insert into public.spa_appointments(request_id,customer_id,staff_id,requested_staff_id,booking_preference,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note)
 values(p_request,customer.id,slot.staff_id,p_staff,case when p_staff is null then 'any' else 'designated' end,slot.room_id,p_service,p_date,p_start,slot.ends_at,slot.blocked_until,case when cfg.auto_confirm then 'confirmed' else 'pending' end,svc.name,svc.price_cents,p_tea,(array[0,12000,15000,12000,18000])[p_tea+1],coalesce(p_note,'')) returning * into booking;
 select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
 perform spa_private.audit('booking.created',booking.id::text,jsonb_build_object('source',case when spa_private.has_permission('appointments.manage') then 'admin' else 'website' end,'preference',booking.booking_preference,'requested_staff_id',p_staff,'assigned_staff_id',booking.staff_id));
 return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference);
end $$;

revoke all on function spa_private.allocation_write_lock(),spa_private.check_staff_booking_window(uuid,date),spa_private.roster_booking_guard(),spa_private.leave_booking_guard(),spa_private.check_store_booking_window(date),spa_private.store_booking_guard(),spa_private.reschedule_candidates(uuid,date,timestamptz,uuid,boolean) from public,anon,authenticated;
revoke all on function public.spa_reschedule_availability(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.spa_reschedule_availability(uuid,date,uuid) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
