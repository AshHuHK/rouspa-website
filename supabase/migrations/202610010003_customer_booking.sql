begin;

-- Short-lived access stays in browser memory; never return permanent manage/review tokens.
create table if not exists public.spa_booking_access (
 token uuid primary key default gen_random_uuid(), customer_id uuid not null references public.spa_customers,
 appointment_id uuid references public.spa_appointments, expires_at timestamptz not null default now()+interval '20 minutes'
);
create index if not exists spa_booking_access_expiry on public.spa_booking_access(expires_at);
create table if not exists public.spa_booking_lookup_limits (
 phone_hash text primary key, window_start timestamptz not null, attempts int not null
);
create table if not exists public.spa_booking_actions (
 request_id uuid primary key, customer_id uuid not null references public.spa_customers,
 appointment_id uuid not null references public.spa_appointments, payload jsonb not null, result jsonb not null,
 created_at timestamptz not null default now()
);
alter table public.spa_booking_access enable row level security;
alter table public.spa_booking_lookup_limits enable row level security;
alter table public.spa_booking_actions enable row level security;
revoke all on public.spa_booking_access,public.spa_booking_lookup_limits,public.spa_booking_actions from public,anon,authenticated;
grant all on public.spa_booking_access,public.spa_booking_lookup_limits,public.spa_booking_actions to service_role;

create or replace function spa_private.booking_summary(a public.spa_appointments) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',a.id,'reference',a.reference,'service_id',a.service_id,'service_name',a.service_name,
 'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,
 'staff_id',a.staff_id,'therapist',(select name from public.spa_staff where id=a.staff_id),
 'price_cents',a.price_cents+a.tea_cents,'change_before',a.starts_at-make_interval(hours=>s.cancellation_hours),
 'can_change',a.status in ('pending','confirmed') and a.starts_at>=now()+make_interval(hours=>s.cancellation_hours))
 from public.spa_settings s
$$;
create or replace function spa_private.booking_access_customer(p_access uuid) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare customer uuid;
begin
 select customer_id into customer from public.spa_booking_access where token=p_access and expires_at>now();
 if customer is null then raise exception 'BOOKING_ACCESS_EXPIRED' using errcode='42501'; end if;
 return customer;
end $$;
create or replace function spa_private.access_appointment(p_access uuid,p_id uuid) returns public.spa_appointments
language plpgsql stable security definer set search_path='' as $$
declare a public.spa_appointments; customer uuid;
begin
 customer:=spa_private.booking_access_customer(p_access);
 select ap.* into a from public.spa_appointments ap join public.spa_booking_access t on t.token=p_access
 where ap.id=p_id and ap.customer_id=customer and (t.appointment_id is null or t.appointment_id=ap.id);
 if a.id is null then raise exception 'NOT_FOUND'; end if;
 return a;
end $$;
create or replace function public.spa_customer_booking_list(p_access uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare customer uuid;
begin
 customer:=spa_private.booking_access_customer(p_access);
 return coalesce((select jsonb_agg(spa_private.booking_summary(a) order by a.starts_at desc)
 from public.spa_appointments a join public.spa_booking_access t on t.token=p_access
 where a.customer_id=customer and (t.appointment_id is null or t.appointment_id=a.id)
 ),'[]');
end $$;

-- User-selected matching rule: both the full phone and full name must match the stored customer.
-- This is a knowledge-based match, not SMS verification of phone ownership.
create or replace function public.spa_server_time() returns timestamptz language sql volatile set search_path='' as $$ select clock_timestamp() $$;
create or replace function public.spa_lookup_bookings(p_phone text,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare tel text; customer uuid; access uuid; attempt int; key_hash text;
begin
 tel:=spa_private.phone(p_phone);
 if tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726003);
 key_hash:=md5(tel);
 insert into public.spa_booking_lookup_limits(phone_hash,window_start,attempts) values(key_hash,now(),1)
 on conflict(phone_hash) do update set
 window_start=case when spa_booking_lookup_limits.window_start<=now()-interval '10 minutes' then now() else spa_booking_lookup_limits.window_start end,
 attempts=case when spa_booking_lookup_limits.window_start<=now()-interval '10 minutes' then 1 else spa_booking_lookup_limits.attempts+1 end
 returning attempts into attempt;
 if attempt>10 then raise exception 'RATE_LIMIT'; end if;
 select id into customer from public.spa_customers where phone=tel and lower(btrim(name))=lower(btrim(p_name));
 if customer is null then return jsonb_build_object('appointments','[]'::jsonb); end if;
 delete from public.spa_booking_access where expires_at<=now();
 delete from public.spa_booking_lookup_limits where window_start<now()-interval '1 day';
 insert into public.spa_booking_access(customer_id) values(customer) returning token into access;
 return jsonb_build_object('access_token',access,'expires_at',now()+interval '20 minutes',
 'appointments',public.spa_customer_booking_list(access));
end $$;
create or replace function public.spa_booking_link_access(p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; access uuid;
begin
 select * into a from public.spa_appointments where manage_token=p_token;
 if a.id is null then return null; end if;
 insert into public.spa_booking_access(customer_id,appointment_id) values(a.customer_id,a.id) returning token into access;
 return jsonb_build_object('access_token',access,'expires_at',now()+interval '20 minutes',
 'appointments',jsonb_build_array(spa_private.booking_summary(a)));
end $$;

-- Use the original booked duration and buffer; ignore only the appointment being moved.
create or replace function spa_private.customer_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select st.id,r.id,p_start+(a.ends_at-a.starts_at),p_start+(a.blocked_until-a.starts_at)
 from public.spa_appointments a join public.spa_services svc on svc.id=a.service_id and svc.active
 cross join public.spa_settings cfg cross join public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=a.service_id
 join public.spa_shifts sh on sh.staff_id=st.id and sh.weekday=extract(dow from p_date)::int
 cross join public.spa_rooms r
 where a.id=p_id and st.active and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(cfg.opening_minute,sh.start_minute))) at time zone cfg.timezone)
 and p_start+(a.blocked_until-a.starts_at)<=((p_date::timestamp+make_interval(mins=>least(cfg.closing_minute,sh.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<p_start+(a.blocked_until-a.starts_at) and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments other where other.id<>a.id and other.status in ('pending','confirmed','checked_in','completed')
  and (other.staff_id=st.id or other.room_id=r.id) and other.starts_at<p_start+(a.blocked_until-a.starts_at) and other.blocked_until>p_start)
 order by (select count(*) from public.spa_appointments b where b.staff_id=st.id and b.business_date=p_date and b.id<>a.id and b.status not in ('cancelled','no_show')),st.display_order,r.name
$$;
create or replace function public.spa_customer_availability(p_access uuid,p_appointment uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available boolean)
language plpgsql stable security definer set search_path='' as $$
declare a public.spa_appointments; cfg public.spa_settings; minute int; start_at timestamptz;
begin
 a:=spa_private.access_appointment(p_access,p_appointment);
 select * into cfg from public.spa_settings;
 if a.status not in ('pending','confirmed') then raise exception 'INVALID_TRANSITION'; end if;
 if a.starts_at<now()+make_interval(hours=>cfg.cancellation_hours) then raise exception 'RESCHEDULE_CUTOFF'; end if;
 if p_date is null or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days then return; end if;
 for minute in select generate_series(cfg.opening_minute,cfg.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI');
  starts_at:=start_at;
  available:=start_at>now()+interval '30 minutes' and exists(select 1 from spa_private.customer_candidates(a.id,p_date,start_at,p_staff));
  return next;
 end loop;
end $$;
create or replace function public.spa_customer_cancel(p_access uuid,p_appointment uuid,p_request uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; saved public.spa_booking_actions; payload jsonb; result jsonb;
begin
 perform pg_advisory_xact_lock(726001);
 a:=spa_private.access_appointment(p_access,p_appointment);
 if p_request is null or p_reason is null or length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 payload:=jsonb_build_object('kind','cancel','reason',btrim(p_reason));
 select * into saved from public.spa_booking_actions where request_id=p_request;
 if found then
  if saved.customer_id<>a.customer_id or saved.appointment_id<>a.id or saved.payload<>payload then raise exception 'REQUEST_CONFLICT'; end if;
  return saved.result;
 end if;
 perform public.spa_cancel_booking(a.manage_token,p_reason);
 select * into a from public.spa_appointments where id=p_appointment;
 result:=spa_private.booking_summary(a);
 insert into public.spa_booking_actions values(p_request,a.customer_id,a.id,payload,result,now());
 return result;
end $$;
create or replace function public.spa_customer_reschedule(p_access uuid,p_appointment uuid,p_request uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; saved public.spa_booking_actions; cfg public.spa_settings; slot record; minute int; payload jsonb; result jsonb; old_start timestamptz;
begin
 perform pg_advisory_xact_lock(726001);
 a:=spa_private.access_appointment(p_access,p_appointment);
 if p_request is null or p_reason is null or length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 payload:=jsonb_build_object('kind','reschedule','date',p_date,'start',p_start,'staff',p_staff,'reason',btrim(p_reason));
 select * into saved from public.spa_booking_actions where request_id=p_request;
 if found then
  if saved.customer_id<>a.customer_id or saved.appointment_id<>a.id or saved.payload<>payload then raise exception 'REQUEST_CONFLICT'; end if;
  return saved.result;
 end if;
 select * into cfg from public.spa_settings;
 if a.status not in ('pending','confirmed') then raise exception 'INVALID_TRANSITION'; end if;
 if a.starts_at<now()+make_interval(hours=>cfg.cancellation_hours) then raise exception 'RESCHEDULE_CUTOFF'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days
  or p_start<=now()+interval '30 minutes' or minute<cfg.opening_minute or minute>=cfg.closing_minute or (minute-cfg.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 select * into slot from spa_private.customer_candidates(a.id,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 old_start:=a.starts_at;
 if a.starts_at<>p_start or a.staff_id<>slot.staff_id then
  update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,
   staff_id=slot.staff_id,room_id=slot.room_id,status=case when cfg.auto_confirm then 'confirmed' else 'pending' end where id=a.id returning * into a;
  perform spa_private.audit('booking.customer_rescheduled',a.id::text,jsonb_build_object('old_start',old_start,'new_start',p_start,'reason',p_reason));
 end if;
 result:=spa_private.booking_summary(a);
 insert into public.spa_booking_actions values(p_request,a.customer_id,a.id,payload,result,now());
 return result;
end $$;

revoke all on function spa_private.booking_summary(public.spa_appointments),spa_private.booking_access_customer(uuid),spa_private.access_appointment(uuid,uuid),spa_private.customer_candidates(uuid,date,timestamptz,uuid) from public,anon,authenticated;
grant execute on function spa_private.booking_summary(public.spa_appointments),spa_private.booking_access_customer(uuid),spa_private.access_appointment(uuid,uuid),spa_private.customer_candidates(uuid,date,timestamptz,uuid) to service_role;
revoke all on function public.spa_server_time(),public.spa_lookup_bookings(text,text),public.spa_booking_link_access(uuid),public.spa_customer_booking_list(uuid),public.spa_customer_availability(uuid,uuid,date,uuid),public.spa_customer_cancel(uuid,uuid,uuid,text),public.spa_customer_reschedule(uuid,uuid,uuid,date,timestamptz,uuid,text) from public;
grant execute on function public.spa_server_time(),public.spa_lookup_bookings(text,text),public.spa_booking_link_access(uuid),public.spa_customer_booking_list(uuid),public.spa_customer_availability(uuid,uuid,date,uuid),public.spa_customer_cancel(uuid,uuid,uuid,text),public.spa_customer_reschedule(uuid,uuid,uuid,date,timestamptz,uuid,text) to anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
