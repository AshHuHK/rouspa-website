begin;

-- Employee schedule entry and public booking share spa_daily_shifts as their
-- final source of truth.  These tables only add submission and approval state.
alter table public.spa_settings
 add column if not exists max_staff_off_per_day int not null default 2
 check(max_staff_off_per_day between 0 and 20);

alter table public.spa_appointments
 add column if not exists requested_staff_id uuid references public.spa_staff,
 add column if not exists booking_preference text not null default 'legacy'
 check(booking_preference in ('legacy','designated','any','admin'));
update public.spa_appointments set requested_staff_id=staff_id where requested_staff_id is null;

create table if not exists public.spa_staff_schedule_submissions (
 id uuid primary key default gen_random_uuid(),
 staff_id uuid not null references public.spa_staff,
 schedule_month date not null check(schedule_month=date_trunc('month',schedule_month)::date),
 version int not null default 1 check(version>0),
 submitted_at timestamptz not null default now(),
 submitted_by uuid not null references auth.users,
 unique(staff_id,schedule_month)
);

create table if not exists public.spa_staff_schedule_change_requests (
 id uuid primary key default gen_random_uuid(),
 staff_id uuid not null references public.spa_staff,
 business_date date not null,
 desired_working boolean not null,
 desired_start_minute int not null,
 desired_end_minute int not null,
 reason text not null check(length(btrim(reason)) between 2 and 1000),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 requested_by uuid not null references auth.users,
 requested_at timestamptz not null default now(),
 reviewed_by uuid references auth.users,
 reviewed_at timestamptz,
 review_note text not null default '' check(length(review_note)<=1000),
 applied_shift_id uuid references public.spa_daily_shifts,
 check(desired_start_minute>=0 and desired_end_minute>desired_start_minute and desired_end_minute<=2880)
);
create unique index if not exists spa_staff_schedule_request_pending
 on public.spa_staff_schedule_change_requests(staff_id,business_date) where status='pending';
create index if not exists spa_staff_schedule_request_status
 on public.spa_staff_schedule_change_requests(status,requested_at desc);

alter table public.spa_staff_schedule_submissions enable row level security;
alter table public.spa_staff_schedule_change_requests enable row level security;
revoke all on public.spa_staff_schedule_submissions,public.spa_staff_schedule_change_requests from public,anon,authenticated;
grant all on public.spa_staff_schedule_submissions,public.spa_staff_schedule_change_requests to service_role;

create or replace function spa_private.current_staff_id()
returns uuid language sql stable security definer set search_path='' as $$
 select r.staff_id from public.spa_roles r
 join public.spa_staff s on s.id=r.staff_id
 where r.user_id=auth.uid() and r.active and s.active and s.employment_status='active' and s.archived_at is null
$$;

create or replace function spa_private.public_booking_last_date()
returns date language sql stable security definer set search_path='' as $$
 select (date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '2 months - 1 day')::date
$$;

create or replace function spa_private.booking_last_date()
returns date language sql stable security definer set search_path='' as $$
 select case when spa_private.has_permission('appointments.manage')
  then (now() at time zone s.timezone)::date+s.booking_days
  else spa_private.public_booking_last_date() end
 from public.spa_settings s
$$;

-- Auto-assignment balances actual booked treatment minutes, not just booking count.
create or replace function spa_private.candidates(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings), hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes) finish,p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s)
 select st.id,r.id,t.finish,t.blocked from public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
 cross join public.spa_rooms r cross join cfg cross join hours h cross join timing t
 where h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
 and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed') and (a.staff_id=st.id or a.room_id=r.id) and a.starts_at<t.blocked and a.blocked_until>p_start)
 order by coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),0),st.display_order,r.name
$$;

create or replace function spa_private.customer_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select st.id,r.id,p_start+(a.ends_at-a.starts_at),p_start+(a.blocked_until-a.starts_at)
 from public.spa_appointments a join public.spa_services svc on svc.id=a.service_id and svc.active and svc.status='active' and svc.online_booking_enabled
 cross join public.spa_settings cfg cross join spa_private.business_window(p_date) h cross join public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=a.service_id and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working cross join public.spa_rooms r
 where a.id=p_id and h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
 and p_start+(a.blocked_until-a.starts_at)<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<p_start+(a.blocked_until-a.starts_at) and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments other where other.id<>a.id and other.status in ('pending','confirmed','checked_in','in_service','completed') and (other.staff_id=st.id or other.room_id=r.id) and other.starts_at<p_start+(a.blocked_until-a.starts_at) and other.blocked_until>p_start)
 order by coalesce((select sum(b.duration_minutes_snapshot) from public.spa_appointments b where b.staff_id=st.id and b.business_date=p_date and b.id<>a.id and b.status not in ('cancelled','no_show')),0),st.display_order,r.name
$$;

create or replace function public.spa_availability(p_service uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available boolean) language plpgsql stable security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.booking_last_date() then return; end if;
 for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI'); starts_at:=start_at;
  available:=start_at>now()+interval '30 minutes' and exists(select 1 from spa_private.candidates(p_service,p_date,start_at,p_staff)); return next;
 end loop;
end $$;

-- Calendar and slot screens only need the number of therapists who can take a
-- start time.  Calculate staff and room capacity independently so these public
-- read paths do not materialize the staff x room candidate matrix (or its
-- workload ordering) for every slot in a two-month calendar.
create or replace function spa_private.available_staff_count(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns int language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings),
 hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s),
 room_capacity as (
  select exists(
   select 1 from public.spa_rooms r cross join timing t
   where r.active and not exists(
    select 1 from public.spa_appointments a
    where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.room_id=r.id
     and a.starts_at<t.blocked and a.blocked_until>p_start
   )
  ) available
 )
 select case when coalesce((select available from room_capacity),false) then coalesce((
  select count(distinct st.id)::int from public.spa_staff st
  join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
  join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
  cross join cfg cross join hours h cross join timing t
  where h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable
   and (p_staff is null or st.id=p_staff)
   and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
   and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
   and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
   and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.staff_id=st.id and a.starts_at<t.blocked and a.blocked_until>p_start)
 ),0) else 0 end
$$;

create index if not exists spa_time_off_staff_time on public.spa_time_off(staff_id,starts_at,ends_at);

create or replace function public.spa_public_slots(p_service uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available_staff_count int,available boolean)
language plpgsql stable security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.public_booking_last_date() then return; end if;
 for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI'); starts_at:=start_at;
  available_staff_count:=case when start_at>now()+interval '30 minutes' then spa_private.available_staff_count(p_service,p_date,start_at,p_staff) else 0 end;
  available:=available_staff_count>0; return next;
 end loop;
end $$;

create or replace function public.spa_public_available_staff(p_service uuid,p_date date,p_start timestamptz)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if p_date<(now() at time zone 'Asia/Taipei')::date or p_date>spa_private.public_booking_last_date() then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.workload_minutes,x.display_order,x.name) from (
  select distinct st.id,st.name,st.name_en,coalesce(j.name,st.title) title,coalesce(j.name_en,'') title_en,st.specialty,st.display_order,
   coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),0)::int workload_minutes
  from spa_private.candidates(p_service,p_date,p_start,null) c join public.spa_staff st on st.id=c.staff_id left join public.spa_job_titles j on j.id=st.job_title_id
 ) x),'[]'::jsonb);
end $$;

create or replace function public.spa_booking_calendar(p_service uuid,p_month date,p_staff uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; month_start date:=date_trunc('month',p_month)::date; month_end date; work_date date; cfg public.spa_settings; hours record; minute int; at_time timestamptz; slot_count int; staff_count int; has_shift boolean; roster_start int; roster_end int; days jsonb:='[]'::jsonb;
begin
 select * into cfg from public.spa_settings; month_end:=(month_start+interval '1 month - 1 day')::date;
 if p_service is null or p_month is null or month_start not in (date_trunc('month',today)::date,(date_trunc('month',today)+interval '1 month')::date) then raise exception 'INVALID_DATE'; end if;
 if not exists(select 1 from public.spa_services where id=p_service and active and status='active' and online_booking_enabled) then raise exception 'INVALID_SERVICE'; end if;
 if p_staff is not null and not exists(select 1 from public.spa_staff st join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled where st.id=p_staff and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 for work_date in select generate_series(month_start,month_end,interval '1 day')::date loop
  select * into hours from spa_private.business_window(work_date);
  slot_count:=0; staff_count:=0; has_shift:=false; roster_start:=null; roster_end:=null;
  if p_staff is not null then select sw.is_working,sw.start_minute,sw.end_minute into has_shift,roster_start,roster_end from spa_private.staff_shift_window(p_staff,work_date) sw; has_shift:=coalesce(has_shift,false);
  else select exists(select 1 from public.spa_staff st join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled join lateral spa_private.staff_shift_window(st.id,work_date) sw on sw.is_working where st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable) into has_shift; end if;
  if work_date>=today and work_date<=spa_private.public_booking_last_date() and coalesce(hours.is_open,false) and has_shift then
   for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
    at_time:=(work_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
    if at_time>now()+interval '30 minutes' then
     staff_count:=spa_private.available_staff_count(p_service,work_date,at_time,p_staff);
     if staff_count>0 then slot_count:=1; exit; end if;
    end if;
   end loop;
  end if;
  days:=days||jsonb_build_array(jsonb_build_object('date',work_date,'is_open',coalesce(hours.is_open,false),'has_shift',has_shift,'available_slots',slot_count,'available_staff',staff_count,'start_minute',case when p_staff is not null and has_shift then roster_start end,'end_minute',case when p_staff is not null and has_shift then roster_end end,'status',case when work_date<today then 'past' when not coalesce(hours.is_open,false) or not has_shift then 'off' when slot_count=0 then 'full' else 'open' end));
 end loop;
 return jsonb_build_object('month',to_char(month_start,'YYYY-MM'),'from',month_start,'to',month_end,'days',days);
end $$;

create or replace function public.spa_create_booking(p_request uuid,p_service uuid,p_date date,p_start timestamptz,p_staff uuid,p_name text,p_phone text,p_tea int default 0,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; svc public.spa_services; slot record; customer uuid; booking public.spa_appointments; tel text; minute int; assigned_name text;
begin
 perform pg_advisory_xact_lock(726001); tel:=spa_private.phone(p_phone);
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 80 or tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_tea is null or p_tea not between 0 and 4 or length(coalesce(p_note,''))>1000 then raise exception 'INVALID_INPUT'; end if;
 select * into booking from public.spa_appointments where request_id=p_request;
 if found then
  if not exists(select 1 from public.spa_customers where id=booking.customer_id and phone=tel) or booking.service_id<>p_service or booking.starts_at<>p_start then raise exception 'REQUEST_CONFLICT'; end if;
  select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
  return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference);
 end if;
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 select * into svc from public.spa_services where id=p_service and active and status='active' and online_booking_enabled;
 if not found then raise exception 'INVALID_SERVICE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.booking_last_date() or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 select id into customer from public.spa_customers where phone=tel;
 if customer is not null and (select count(*) from public.spa_appointments where customer_id=customer and created_at>now()-interval '24 hours')>=5 then raise exception 'RATE_LIMIT'; end if;
 select * into slot from spa_private.candidates(p_service,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 if customer is null then insert into public.spa_customers(name,phone) values(btrim(p_name),tel) returning id into customer;
 else update public.spa_customers set name=btrim(p_name),archived_at=null,status='active' where id=customer; end if;
 insert into public.spa_appointments(request_id,customer_id,staff_id,requested_staff_id,booking_preference,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note)
 values(p_request,customer,slot.staff_id,p_staff,case when p_staff is null then 'any' else 'designated' end,slot.room_id,p_service,p_date,p_start,slot.ends_at,slot.blocked_until,case when cfg.auto_confirm then 'confirmed' else 'pending' end,svc.name,svc.price_cents,p_tea,(array[0,12000,15000,12000,18000])[p_tea+1],coalesce(p_note,'')) returning * into booking;
 select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
 perform spa_private.audit('booking.created',booking.id::text,jsonb_build_object('source','website','preference',booking.booking_preference,'requested_staff_id',p_staff,'assigned_staff_id',booking.staff_id));
 return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference);
end $$;

create or replace function public.spa_customer_availability(p_access uuid,p_appointment uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available boolean)
language plpgsql stable security definer set search_path='' as $$
declare a public.spa_appointments; cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 a:=spa_private.access_appointment(p_access,p_appointment); select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if a.status not in ('pending','confirmed') then raise exception 'INVALID_TRANSITION'; end if;
 if a.starts_at<now()+make_interval(hours=>cfg.cancellation_hours) then raise exception 'RESCHEDULE_CUTOFF'; end if;
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.public_booking_last_date() then return; end if;
 for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI'); starts_at:=start_at;
  available:=start_at>now()+interval '30 minutes' and exists(select 1 from spa_private.customer_candidates(a.id,p_date,start_at,p_staff)); return next;
 end loop;
end $$;

create or replace function public.spa_customer_reschedule(p_access uuid,p_appointment uuid,p_request uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; saved public.spa_booking_actions; cfg public.spa_settings; hours record; slot record; minute int; payload jsonb; result jsonb; old_start timestamptz;
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
  update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,staff_id=slot.staff_id,room_id=slot.room_id,status=case when cfg.auto_confirm then 'confirmed' else 'pending' end where id=a.id returning * into a;
  perform spa_private.audit('booking.customer_rescheduled',a.id::text,jsonb_build_object('old_start',old_start,'new_start',p_start,'reason',p_reason));
 end if;
 result:=spa_private.booking_summary(a); insert into public.spa_booking_actions values(p_request,a.customer_id,a.id,payload,result,now()); return result;
end $$;

create or replace function public.spa_staff_schedule_plan()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid:=spa_private.current_staff_id(); today date:=(now() at time zone 'Asia/Taipei')::date; target date:=(date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '1 month')::date; final_date date; day_rows jsonb;
begin
 perform spa_private.require_team(); if person is null then raise exception 'STAFF_NOT_ACTIVE'; end if; final_date:=(target+interval '1 month - 1 day')::date;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.business_date),'[]'::jsonb) into day_rows from (
  select d.business_date::date business_date,sw.is_working,sw.start_minute,sw.end_minute,sw.source,sw.note,
   (select count(*) from public.spa_appointments a where a.staff_id=person and a.business_date=d.business_date::date and a.status not in ('cancelled','no_show'))::int appointment_count,
   not exists(select 1 from public.spa_appointments a where a.staff_id=person and a.business_date=d.business_date::date and a.status in ('pending','confirmed','checked_in','in_service')) can_turn_off,
   (select count(*) from public.spa_staff st join lateral spa_private.staff_shift_window(st.id,d.business_date::date) other on not other.is_working where st.active and st.employment_status='active' and st.archived_at is null)::int off_count
  from generate_series(target,final_date,interval '1 day') d(business_date)
  cross join lateral spa_private.staff_shift_window(person,d.business_date::date) sw
 ) x;
 return jsonb_build_object('today',today,'target_month',target,'target_end',final_date,'edit_open',extract(day from today)::int between 1 and 7,'edit_deadline',(date_trunc('month',today)+interval '6 days')::date,'max_off_per_day',(select max_staff_off_per_day from public.spa_settings),
  'staff',(select jsonb_build_object('id',s.id,'name',s.name,'title',coalesce(j.name,s.title)) from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id where s.id=person),
  'submission',(select to_jsonb(q) from public.spa_staff_schedule_submissions q where q.staff_id=person and q.schedule_month=target),
  'days',day_rows,
  'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.requested_at desc) from public.spa_staff_schedule_change_requests r where r.staff_id=person and r.business_date>=today-30),'[]'::jsonb));
end $$;

create or replace function public.spa_staff_schedule_submit(p_month date,p_days jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.current_staff_id(); today date:=(now() at time zone 'Asia/Taipei')::date; target date:=(date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '1 month')::date; final_date date; expected int; item jsonb; work_date date; working boolean; start_min int; end_min int; shift_id uuid; maximum int;
begin
 perform spa_private.require_team(); perform pg_advisory_xact_lock(726101);
 if person is null then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if extract(day from today)::int not between 1 and 7 then raise exception 'SCHEDULE_LOCKED'; end if;
 if p_month is null or date_trunc('month',p_month)::date<>target or p_days is null or jsonb_typeof(p_days)<>'array' then raise exception 'INVALID_SCHEDULE'; end if;
 final_date:=(target+interval '1 month - 1 day')::date; expected:=final_date-target+1;
 if jsonb_array_length(p_days)<>expected or (select count(distinct x->>'date') from jsonb_array_elements(p_days) x)<>expected
  or exists(select 1 from jsonb_array_elements(p_days) x where (x->>'date')::date not between target and final_date) then raise exception 'INVALID_SCHEDULE'; end if;
 select max_staff_off_per_day into maximum from public.spa_settings;
 for item in select * from jsonb_array_elements(p_days) loop
  work_date:=(item->>'date')::date; working:=coalesce((item->>'is_working')::boolean,false); start_min:=coalesce((item->>'start_minute')::int,600); end_min:=coalesce((item->>'end_minute')::int,1320);
  if start_min<0 or end_min<=start_min or end_min>2880 then raise exception 'INVALID_SCHEDULE'; end if;
  if exists(select 1 from public.spa_appointments a cross join public.spa_settings cfg where a.staff_id=person and a.business_date=work_date and a.status in ('pending','confirmed','checked_in','in_service') and (not working or a.starts_at<((work_date::timestamp+make_interval(mins=>start_min)) at time zone cfg.timezone) or a.blocked_until>((work_date::timestamp+make_interval(mins=>end_min)) at time zone cfg.timezone))) then raise exception 'EXISTING_BOOKINGS'; end if;
  if not working and (select count(*) from public.spa_staff st join lateral spa_private.staff_shift_window(st.id,work_date) sw on not sw.is_working where st.id<>person and st.active and st.employment_status='active' and st.archived_at is null)>=maximum then raise exception 'OFF_LIMIT'; end if;
  insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
  values(person,work_date,working,start_min,end_min,'員工月班表',auth.uid(),now())
  on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at returning id into shift_id;
 end loop;
 insert into public.spa_staff_schedule_submissions(staff_id,schedule_month,submitted_by)
 values(person,target,auth.uid()) on conflict(staff_id,schedule_month) do update set version=spa_staff_schedule_submissions.version+1,submitted_at=now(),submitted_by=auth.uid();
 perform spa_private.audit('schedule.employee_submitted',person::text,jsonb_build_object('month',target,'days',expected));
 return (select to_jsonb(s) from public.spa_staff_schedule_submissions s where s.staff_id=person and s.schedule_month=target);
end $$;

create or replace function public.spa_staff_schedule_request(p_date date,p_working boolean,p_start int,p_end int,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.current_staff_id(); today date:=(now() at time zone 'Asia/Taipei')::date; target date:=(date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '1 month')::date; result uuid;
begin
 perform spa_private.require_team();
 if person is null then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_date is null or p_date<today or p_date>(target+interval '1 month - 1 day')::date or p_working is null or p_start<0 or p_end<=p_start or p_end>2880 or length(btrim(coalesce(p_reason,''))) not between 2 and 1000 then raise exception 'INVALID_INPUT'; end if;
 if extract(day from today)::int between 1 and 7 and p_date between target and (target+interval '1 month - 1 day')::date then raise exception 'SCHEDULE_EDIT_OPEN'; end if;
 insert into public.spa_staff_schedule_change_requests(staff_id,business_date,desired_working,desired_start_minute,desired_end_minute,reason,requested_by)
 values(person,p_date,p_working,p_start,p_end,btrim(p_reason),auth.uid()) returning id into result;
 perform spa_private.audit('schedule.change_requested',result::text,jsonb_build_object('staff_id',person,'date',p_date,'working',p_working)); return result;
end $$;

create or replace function public.spa_staff_schedule_request_review(p_id uuid,p_approve boolean,p_note text default '')
returns void language plpgsql security definer set search_path='' as $$
declare request public.spa_staff_schedule_change_requests; cfg public.spa_settings; shift_id uuid; range_start timestamptz; range_end timestamptz;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726101);
 select * into request from public.spa_staff_schedule_change_requests where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if; if request.status<>'pending' then raise exception 'INVALID_TRANSITION'; end if;
 if p_approve then
  select * into cfg from public.spa_settings; range_start:=(request.business_date::timestamp+make_interval(mins=>request.desired_start_minute)) at time zone cfg.timezone; range_end:=(request.business_date::timestamp+make_interval(mins=>request.desired_end_minute)) at time zone cfg.timezone;
  if exists(select 1 from public.spa_appointments a where a.staff_id=request.staff_id and a.business_date=request.business_date and a.status in ('pending','confirmed','checked_in','in_service') and (not request.desired_working or a.starts_at<range_start or a.blocked_until>range_end)) then raise exception 'EXISTING_BOOKINGS'; end if;
  insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
  values(request.staff_id,request.business_date,request.desired_working,request.desired_start_minute,request.desired_end_minute,'核准員工變更：'||request.reason,auth.uid(),now())
  on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at returning id into shift_id;
 end if;
 update public.spa_staff_schedule_change_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=auth.uid(),reviewed_at=now(),review_note=btrim(coalesce(p_note,'')),applied_shift_id=shift_id where id=p_id;
 perform spa_private.audit('schedule.change_reviewed',p_id::text,jsonb_build_object('approved',p_approve,'note',p_note));
end $$;

create or replace function public.spa_schedule_admin()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; target date:=(date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '1 month')::date;
begin
 perform spa_private.require_permission('team.view');
 return jsonb_build_object('target_month',target,'edit_open',extract(day from today)::int between 1 and 7,'max_off_per_day',(select max_staff_off_per_day from public.spa_settings),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'title',coalesce(j.name,s.title),'submission',to_jsonb(q)) order by s.display_order,s.name) from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id left join public.spa_staff_schedule_submissions q on q.staff_id=s.id and q.schedule_month=target where s.active and s.employment_status='active' and s.archived_at is null),'[]'::jsonb),
 'requests',case when spa_private.has_permission('team.manage') then coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('staff_name',s.name,'staff_title',coalesce(j.name,s.title)) order by (r.status='pending') desc,r.requested_at desc) from public.spa_staff_schedule_change_requests r join public.spa_staff s on s.id=r.staff_id left join public.spa_job_titles j on j.id=s.job_title_id where r.requested_at>now()-interval '90 days'),'[]'::jsonb) else '[]'::jsonb end);
end $$;

create or replace function public.spa_schedule_policy_save(p_max_off int)
returns void language plpgsql security definer set search_path='' as $$
begin perform spa_private.require_permission('settings.manage'); if p_max_off is null or p_max_off not between 0 and 20 then raise exception 'INVALID_INPUT'; end if; update public.spa_settings set max_staff_off_per_day=p_max_off; perform spa_private.audit('schedule.policy_saved','store',jsonb_build_object('max_staff_off_per_day',p_max_off)); end $$;

-- Staff and owner use the same monthly read model. Customer identity is reduced
-- to the surname for non-managers and each employee can highlight own work.
create or replace function public.spa_monthly_operations(p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare month_start date:=date_trunc('month',p_month)::date; month_end date; work_date date; day_start timestamptz; day_end timestamptz; hours jsonb; shifts jsonb; rests jsonb; leaves jsonb; appointments jsonb; days jsonb:='[]'::jsonb; can_manage boolean:=spa_private.has_permission('appointments.manage'); viewer uuid:=spa_private.current_staff_id();
begin
 perform spa_private.require_permission('dashboard.view'); if p_month is null then raise exception 'INVALID_DATE'; end if; month_end:=(month_start+interval '1 month - 1 day')::date;
 for work_date in select generate_series(month_start,month_end,interval '1 day')::date loop
  day_start:=work_date::timestamp at time zone 'Asia/Taipei'; day_end:=(work_date+1)::timestamp at time zone 'Asia/Taipei'; select to_jsonb(w) into hours from spa_private.business_window(work_date) w;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'start_minute',roster.start_minute,'end_minute',roster.end_minute,'source',roster.source,'note',roster.note,'is_own',s.id=viewer) order by roster.start_minute,s.display_order,s.name),'[]'::jsonb) into shifts from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id cross join lateral spa_private.staff_shift_window(s.id,work_date) roster where s.active and s.employment_status='active' and s.archived_at is null and roster.is_working;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'source',roster.source,'note',roster.note,'is_own',s.id=viewer) order by s.display_order,s.name),'[]'::jsonb) into rests from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id cross join lateral spa_private.staff_shift_window(s.id,work_date) roster where s.active and s.employment_status='active' and s.archived_at is null and not roster.is_working;
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'starts_at',o.starts_at,'ends_at',o.ends_at,'reason',o.reason,'is_own',s.id=viewer) order by o.starts_at,s.display_order,s.name),'[]'::jsonb) into leaves from public.spa_time_off o join public.spa_staff s on s.id=o.staff_id left join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and o.starts_at<day_end and o.ends_at>day_start;
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'reference',a.reference,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'customer_name',case when can_manage then c.name else left(btrim(c.name),1)||'小姐' end,'service_name',coalesce(a.service_name_snapshot,a.service_name),'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),'room_id',r.id,'room_name',r.name,'is_own',s.id=viewer) order by a.starts_at,r.name),'[]'::jsonb) into appointments from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id left join public.spa_job_titles j on j.id=s.job_title_id join public.spa_rooms r on r.id=a.room_id where a.business_date=work_date and a.status not in ('cancelled','no_show');
  days:=days||jsonb_build_array(jsonb_build_object('date',work_date,'store_hours',coalesce(hours,'{}'::jsonb),'shift_count',jsonb_array_length(shifts),'off_count',(select count(distinct staff_id) from (select (x->>'staff_id')::uuid staff_id from jsonb_array_elements(rests) x union all select (x->>'staff_id')::uuid from jsonb_array_elements(leaves) x) off_people),'appointment_count',jsonb_array_length(appointments),'room_count',(select count(distinct x->>'room_id') from jsonb_array_elements(appointments) x),'shifts',shifts,'rests',rests,'leaves',leaves,'appointments',appointments));
 end loop;
 return jsonb_build_object('month',to_char(month_start,'YYYY-MM'),'from',month_start,'to',month_end,'active_staff_count',(select count(*) from public.spa_staff where active and employment_status='active' and archived_at is null),'active_room_count',(select count(*) from public.spa_rooms where active),'viewer_staff_id',viewer,'can_manage_appointments',can_manage,'days',days);
end $$;

create or replace function public.spa_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; owner_view boolean:=spa_private.role_name()='owner'; can_manage boolean:=spa_private.has_permission('appointments.manage');
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object('date',today,'appointments',(select count(*) from public.spa_appointments where business_date=today),'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',case when owner_view then coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.business_date=today and ch.refunded_at is null),0) end,
  'staff_working',(select count(*) from public.spa_staff s join lateral spa_private.staff_shift_window(s.id,today) roster on roster.is_working where s.active and s.employment_status='active' and s.archived_at is null),
  'rooms_active',(select count(*) from public.spa_rooms where active),'new_members',case when owner_view then (select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today) end,
  'low_stock',case when owner_view then (select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold) end,
  'today_hours',(select to_jsonb(w) from spa_private.business_window(today) w),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,case when can_manage then c.name else left(btrim(c.name),1)||'小姐' end customer_name,s.name staff_name,r.name resource_name from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

revoke all on function public.spa_public_slots(uuid,date,uuid),public.spa_public_available_staff(uuid,date,timestamptz),public.spa_booking_calendar(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.spa_public_slots(uuid,date,uuid),public.spa_public_available_staff(uuid,date,timestamptz),public.spa_booking_calendar(uuid,date,uuid) to anon,authenticated,service_role;
revoke all on function public.spa_staff_schedule_plan(),public.spa_staff_schedule_submit(date,jsonb),public.spa_staff_schedule_request(date,boolean,int,int,text),public.spa_staff_schedule_request_review(uuid,boolean,text),public.spa_schedule_admin(),public.spa_schedule_policy_save(int) from public,anon,authenticated;
grant execute on function public.spa_staff_schedule_plan(),public.spa_staff_schedule_submit(date,jsonb),public.spa_staff_schedule_request(date,boolean,int,int,text),public.spa_staff_schedule_request_review(uuid,boolean,text),public.spa_schedule_admin(),public.spa_schedule_policy_save(int) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
