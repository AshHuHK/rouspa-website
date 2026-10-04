begin;

-- Weekly store hours and one-day overrides are the single source of truth for
-- the public site, booking availability, customer rescheduling and admin UI.
create table if not exists public.spa_business_hours (
 weekday int primary key check(weekday between 0 and 6),
 is_open boolean not null default true,
 opening_minute int not null default 600,
 closing_minute int not null default 1560,
 updated_by uuid references auth.users,
 updated_at timestamptz not null default now(),
 check(opening_minute>=0 and closing_minute>opening_minute and closing_minute<=2880)
);
insert into public.spa_business_hours(weekday,is_open,opening_minute,closing_minute)
select weekday,true,s.opening_minute,s.closing_minute
from generate_series(0,6) weekday cross join public.spa_settings s
on conflict(weekday) do nothing;

create table if not exists public.spa_business_day_overrides (
 business_date date primary key,
 is_open boolean not null,
 opening_minute int not null default 600,
 closing_minute int not null default 1560,
 note text not null default '',
 updated_by uuid references auth.users,
 updated_at timestamptz not null default now(),
 check(opening_minute>=0 and closing_minute>opening_minute and closing_minute<=2880),
 check(length(note)<=500)
);

create or replace function spa_private.business_window(p_date date)
returns table(is_open boolean,opening_minute int,closing_minute int,source text,note text)
language sql stable security definer set search_path='' as $$
 select coalesce(o.is_open,h.is_open),coalesce(o.opening_minute,h.opening_minute),coalesce(o.closing_minute,h.closing_minute),
  case when o.business_date is null then 'weekly' else 'override' end,coalesce(o.note,'')
 from public.spa_business_hours h
 left join public.spa_business_day_overrides o on o.business_date=p_date
 where h.weekday=extract(dow from p_date)::int
$$;

create or replace function spa_private.candidates(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings), hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes) finish,p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s)
 select st.id,r.id,t.finish,t.blocked from public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
 join public.spa_shifts sh on sh.staff_id=st.id and sh.weekday=extract(dow from p_date)::int
 cross join public.spa_rooms r cross join cfg cross join hours h cross join timing t
 where h.is_open and st.active and st.archived_at is null and st.is_bookable and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,sh.start_minute))) at time zone cfg.timezone)
 and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,sh.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed') and (a.staff_id=st.id or a.room_id=r.id) and a.starts_at<t.blocked and a.blocked_until>p_start)
 order by (select count(*) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),st.display_order,r.name
$$;

create or replace function public.spa_availability(p_service uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available boolean) language plpgsql stable security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 select * into cfg from public.spa_settings;
 select * into hours from spa_private.business_window(p_date);
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days then return; end if;
 for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI');
  starts_at:=start_at;
  available:=start_at>now()+interval '30 minutes' and exists(select 1 from spa_private.candidates(p_service,p_date,start_at,p_staff));
  return next;
 end loop;
end $$;

create or replace function public.spa_create_booking(p_request uuid,p_service uuid,p_date date,p_start timestamptz,p_staff uuid,p_name text,p_phone text,p_tea int default 0,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; svc public.spa_services; slot record; customer uuid; booking public.spa_appointments; tel text; minute int;
begin
 perform pg_advisory_xact_lock(726001);
 tel:=spa_private.phone(p_phone);
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 80 or tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_tea is null or p_tea not between 0 and 4 or length(coalesce(p_note,''))>1000 then raise exception 'INVALID_INPUT'; end if;
 select * into booking from public.spa_appointments where request_id=p_request;
 if found then
  if not exists(select 1 from public.spa_customers where id=booking.customer_id and phone=tel) or booking.service_id<>p_service or booking.starts_at<>p_start then raise exception 'REQUEST_CONFLICT'; end if;
  return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token);
 end if;
 select * into cfg from public.spa_settings;
 select * into hours from spa_private.business_window(p_date);
 select * into svc from public.spa_services where id=p_service and active and status='active' and online_booking_enabled;
 if not found then raise exception 'INVALID_SERVICE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 select id into customer from public.spa_customers where phone=tel;
 if customer is not null and (select count(*) from public.spa_appointments where customer_id=customer and created_at>now()-interval '24 hours')>=5 then raise exception 'RATE_LIMIT'; end if;
 select * into slot from spa_private.candidates(p_service,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 if customer is null then insert into public.spa_customers(name,phone) values(btrim(p_name),tel) returning id into customer;
 else update public.spa_customers set archived_at=null,status='active' where id=customer and archived_at is not null; end if;
 insert into public.spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note)
 values(p_request,customer,slot.staff_id,slot.room_id,p_service,p_date,p_start,slot.ends_at,slot.blocked_until,case when cfg.auto_confirm then 'confirmed' else 'pending' end,svc.name,svc.price_cents,p_tea,(array[0,12000,15000,12000,18000])[p_tea+1],coalesce(p_note,'')) returning * into booking;
 perform spa_private.audit('booking.created',booking.id::text,jsonb_build_object('source','website'));
 return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token);
end $$;

create or replace function spa_private.customer_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select st.id,r.id,p_start+(a.ends_at-a.starts_at),p_start+(a.blocked_until-a.starts_at)
 from public.spa_appointments a join public.spa_services svc on svc.id=a.service_id and svc.active and svc.status='active' and svc.online_booking_enabled
 cross join public.spa_settings cfg cross join spa_private.business_window(p_date) h cross join public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=a.service_id and sk.enabled
 join public.spa_shifts sh on sh.staff_id=st.id and sh.weekday=extract(dow from p_date)::int cross join public.spa_rooms r
 where a.id=p_id and h.is_open and st.active and st.archived_at is null and st.is_bookable and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,sh.start_minute))) at time zone cfg.timezone)
 and p_start+(a.blocked_until-a.starts_at)<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,sh.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<p_start+(a.blocked_until-a.starts_at) and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments other where other.id<>a.id and other.status in ('pending','confirmed','checked_in','in_service','completed') and (other.staff_id=st.id or other.room_id=r.id) and other.starts_at<p_start+(a.blocked_until-a.starts_at) and other.blocked_until>p_start)
 order by (select count(*) from public.spa_appointments b where b.staff_id=st.id and b.business_date=p_date and b.id<>a.id and b.status not in ('cancelled','no_show')),st.display_order,r.name
$$;

create or replace function public.spa_customer_availability(p_access uuid,p_appointment uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available boolean)
language plpgsql stable security definer set search_path='' as $$
declare a public.spa_appointments; cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 a:=spa_private.access_appointment(p_access,p_appointment); select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if a.status not in ('pending','confirmed') then raise exception 'INVALID_TRANSITION'; end if;
 if a.starts_at<now()+make_interval(hours=>cfg.cancellation_hours) then raise exception 'RESCHEDULE_CUTOFF'; end if;
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days then return; end if;
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
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 select * into slot from spa_private.customer_candidates(a.id,p_date,p_start,p_staff) limit 1; if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 old_start:=a.starts_at;
 if a.starts_at<>p_start or a.staff_id<>slot.staff_id then
  update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,staff_id=slot.staff_id,room_id=slot.room_id,status=case when cfg.auto_confirm then 'confirmed' else 'pending' end where id=a.id returning * into a;
  perform spa_private.audit('booking.customer_rescheduled',a.id::text,jsonb_build_object('old_start',old_start,'new_start',p_start,'reason',p_reason));
 end if;
 result:=spa_private.booking_summary(a); insert into public.spa_booking_actions values(p_request,a.customer_id,a.id,payload,result,now()); return result;
end $$;

-- Employees have a deliberately small, fixed view: dashboard, store schedule,
-- reviews and their own self-service performance/pay page.
insert into public.spa_permission_definitions(code,name,module,display_order)
values('reviews.view','查看評價','operations',39)
on conflict(code) do update set name=excluded.name,module=excluded.module,display_order=excluded.display_order;
insert into public.spa_role_permissions(role_code,permission_code) values('owner','reviews.view') on conflict do nothing;
delete from public.spa_role_permissions where role_code<>'owner';
insert into public.spa_role_permissions(role_code,permission_code)
select r.code,p.code from public.spa_role_profiles r cross join (values('dashboard.view'),('appointments.view'),('reviews.view')) p(code)
where r.code<>'owner' on conflict do nothing;

create or replace function public.spa_role_profile_save(p_code text,p_name text,p_permissions text[],p_active boolean,p_display_order int) returns void
language plpgsql security definer set search_path='' as $$
declare normalized text:=lower(btrim(p_code)); old jsonb;
begin
 perform spa_private.require_permission('settings.manage');
 if normalized='owner' then raise exception 'OWNER_PROTECTED'; end if;
 if normalized !~ '^[a-z][a-z0-9_]{1,31}$' or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from unnest(coalesce(p_permissions,'{}'::text[])) x where x not in ('dashboard.view','appointments.view','reviews.view')) then raise exception 'STAFF_PERMISSION_LIMIT'; end if;
 select to_jsonb(r)||jsonb_build_object('permissions',coalesce((select jsonb_agg(permission_code) from public.spa_role_permissions where role_code=r.code),'[]'::jsonb)) into old from public.spa_role_profiles r where code=normalized;
 insert into public.spa_role_profiles(code,name,active,display_order) values(normalized,btrim(p_name),p_active,p_display_order)
 on conflict(code) do update set name=excluded.name,active=excluded.active,display_order=excluded.display_order,archived_at=case when excluded.active then null else coalesce(spa_role_profiles.archived_at,now()) end;
 delete from public.spa_role_permissions where role_code=normalized;
 insert into public.spa_role_permissions(role_code,permission_code) values(normalized,'dashboard.view'),(normalized,'appointments.view'),(normalized,'reviews.view');
 perform spa_private.audit('role_profile.saved',normalized,jsonb_build_object('old',old,'new',jsonb_build_object('name',p_name,'active',p_active,'permissions',jsonb_build_array('dashboard.view','appointments.view','reviews.view'))));
end $$;

create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare can_manage boolean:=spa_private.has_permission('appointments.manage');
begin
 perform spa_private.require_permission('appointments.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(
  (case when can_manage then to_jsonb(a) else jsonb_build_object('id',a.id,'reference',a.reference,'staff_id',a.staff_id,'service_id',a.service_id,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'service_name',a.service_name_snapshot) end)
  ||jsonb_build_object('customer_name',c.name,'phone',case when can_manage then c.phone else null end,'therapist',coalesce(a.staff_name_snapshot,s.name),'room',r.name,'checkout',case when spa_private.has_permission('finance.view') then to_jsonb(ch) else null end) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id left join public.spa_checkouts ch on ch.appointment_id=a.id
  where a.business_date between p_from and p_to),'[]');
end $$;

create or replace function public.spa_reviews_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('reviews.view');
 return jsonb_build_object('reviews',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('customer_name',c.name,'therapist',s.name,'reference',a.reference) order by r.created_at desc) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id),'[]'),
 'feedback',case when spa_private.has_permission('reviews.manage') then coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from public.spa_feedback f),'[]') else '[]'::jsonb end);
end $$;

-- Customer profiles distinguish walk-in/consumer records from enrolled members.
-- Profiles with history are archived instead of hard-deleted so ledgers remain auditable.
alter table public.spa_customers add column if not exists customer_type text not null default 'guest' check(customer_type in ('guest','member'));
alter table public.spa_customers add column if not exists archived_at timestamptz;
update public.spa_customers c set customer_type='member'
where c.auth_user_id is not null or exists(select 1 from public.spa_wallet_entries w where w.customer_id=c.id) or exists(select 1 from public.spa_packages p where p.customer_id=c.id);

create or replace function public.spa_customer_save_v2(p_id uuid,p_name text,p_phone text,p_email text,p_tier text,p_notes text,p_customer_type text,p_user uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('customers.manage');
 if length(btrim(coalesce(p_name,'')))=0 or length(coalesce(p_notes,''))>4000 or length(coalesce(p_email,''))>254 or p_customer_type not in ('guest','member') then raise exception 'INVALID_INPUT'; end if;
 if p_id is null then
  insert into public.spa_customers(name,phone,email,tier,notes,customer_type,auth_user_id) values(btrim(p_name),spa_private.phone(p_phone),coalesce(p_email,''),coalesce(nullif(btrim(p_tier),''),'一般會員'),coalesce(p_notes,''),p_customer_type,p_user) returning id into result;
 else
  update public.spa_customers set name=btrim(p_name),phone=spa_private.phone(p_phone),email=coalesce(p_email,''),tier=coalesce(nullif(btrim(p_tier),''),'一般會員'),notes=coalesce(p_notes,''),customer_type=p_customer_type,auth_user_id=p_user where id=p_id returning id into result;
 end if;
 if result is null then raise exception 'NOT_FOUND'; end if; perform spa_private.audit('customer.saved',result::text,jsonb_build_object('customer_type',p_customer_type)); return result;
end $$;

create or replace function public.spa_customer_delete(p_customer uuid,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.spa_customers; has_history boolean;
begin
 perform spa_private.require_permission('customers.manage'); if p_confirmation<>'DELETE' then raise exception 'CUSTOMER_DELETE_CONFIRMATION_REQUIRED'; end if;
 select * into c from public.spa_customers where id=p_customer for update; if not found then raise exception 'NOT_FOUND'; end if;
 has_history:=exists(select 1 from public.spa_appointments where customer_id=p_customer) or exists(select 1 from public.spa_wallet_entries where customer_id=p_customer) or exists(select 1 from public.spa_packages where customer_id=p_customer) or exists(select 1 from public.spa_cash_entries where customer_id=p_customer) or exists(select 1 from public.spa_orders where customer_id=p_customer);
 if has_history then
  update public.spa_customers set archived_at=now(),status='inactive',auth_user_id=null where id=p_customer;
  perform spa_private.audit('customer.archived',p_customer::text,jsonb_build_object('reason','history_preserved')); return jsonb_build_object('mode','archived');
 end if;
 delete from public.spa_booking_access where customer_id=p_customer; delete from public.spa_customers where id=p_customer;
 perform spa_private.audit('customer.deleted',p_customer::text); return jsonb_build_object('mode','deleted');
end $$;

create or replace function public.spa_customer_restore(p_customer uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.manage'); update public.spa_customers set archived_at=null,status='active' where id=p_customer;
 if not found then raise exception 'NOT_FOUND'; end if; perform spa_private.audit('customer.restored',p_customer::text);
end $$;

create or replace function public.spa_customers_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.view');
 return coalesce((select jsonb_agg((case when spa_private.has_permission('customers.manage') then to_jsonb(c) else jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'tier',c.tier,'status',c.status,'customer_type',c.customer_type,'archived_at',c.archived_at) end)
  ||jsonb_build_object('balance_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries where customer_id=c.id),0),'visits',(select count(*) from public.spa_appointments where customer_id=c.id and status='completed'),'no_shows',(select count(*) from public.spa_appointments where customer_id=c.id and status='no_show'),'total_spend_cents',coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.customer_id=c.id and ch.refunded_at is null),0),'last_visit',(select max(starts_at) from public.spa_appointments where customer_id=c.id and status='completed')) order by c.archived_at nulls first,c.created_at desc) from public.spa_customers c),'[]');
end $$;

create or replace function public.spa_topup(p_request uuid,p_customer uuid,p_cents bigint,p_method text,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.manage'); perform 1 from public.spa_customers where id=p_customer and archived_at is null for update;
 if not found or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method not in ('cash','card','transfer') or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_wallet_entries where request_id=p_request) then return; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'topup',p_request,p_note,auth.uid());
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'topup',p_method,p_note,auth.uid());
 update public.spa_customers set customer_type='member' where id=p_customer;
 perform spa_private.audit('wallet.topup',p_customer::text,jsonb_build_object('cents',p_cents));
end $$;

create or replace function public.spa_package_sell(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.manage'); perform 1 from public.spa_customers where id=p_customer and archived_at is null for update;
 if not found or p_sessions not between 1 and 200 or p_expires is null or p_expires<=now() or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method not in ('cash','card','transfer') or length(btrim(p_name))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_packages where request_id=p_request) then return; end if;
 insert into public.spa_packages(customer_id,service_id,name,sessions,paid_cents,expires_at,request_id) values(p_customer,p_service,p_name,p_sessions,p_cents,p_expires,p_request);
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'package',p_method,p_name,auth.uid());
 update public.spa_customers set customer_type='member' where id=p_customer;
 perform spa_private.audit('package.sold',p_customer::text,jsonb_build_object('sessions',p_sessions,'cents',p_cents));
end $$;

create or replace function public.spa_business_hours_save(p_hours jsonb) returns void language plpgsql security definer set search_path='' as $$
declare row jsonb;
begin
 perform spa_private.require_permission('settings.manage');
 if jsonb_typeof(p_hours)<>'array' or jsonb_array_length(p_hours)<>7 or (select count(distinct (x->>'weekday')::int) from jsonb_array_elements(p_hours) x)<>7 then raise exception 'INVALID_INPUT'; end if;
 for row in select * from jsonb_array_elements(p_hours) loop
  if (row->>'weekday')::int not between 0 and 6 or (row->>'opening_minute')::int<0 or (row->>'closing_minute')::int<=(row->>'opening_minute')::int or (row->>'closing_minute')::int>2880 then raise exception 'INVALID_INPUT'; end if;
  insert into public.spa_business_hours(weekday,is_open,opening_minute,closing_minute,updated_by,updated_at)
  values((row->>'weekday')::int,(row->>'is_open')::boolean,(row->>'opening_minute')::int,(row->>'closing_minute')::int,auth.uid(),now())
  on conflict(weekday) do update set is_open=excluded.is_open,opening_minute=excluded.opening_minute,closing_minute=excluded.closing_minute,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 end loop;
 perform spa_private.audit('business_hours.saved','weekly',jsonb_build_object('hours',p_hours));
end $$;

create or replace function public.spa_business_day_override_save(p_date date,p_is_open boolean,p_open int,p_close int,p_note text default '') returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 if p_date is null or p_is_open is null or p_open<0 or p_close<=p_open or p_close>2880 or length(coalesce(p_note,''))>500 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_business_day_overrides(business_date,is_open,opening_minute,closing_minute,note,updated_by,updated_at)
 values(p_date,p_is_open,p_open,p_close,btrim(coalesce(p_note,'')),auth.uid(),now())
 on conflict(business_date) do update set is_open=excluded.is_open,opening_minute=excluded.opening_minute,closing_minute=excluded.closing_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 perform spa_private.audit('business_hours.override_saved',p_date::text,jsonb_build_object('open',p_is_open,'opening_minute',p_open,'closing_minute',p_close,'note',p_note));
end $$;

create or replace function public.spa_business_day_override_delete(p_date date) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage'); delete from public.spa_business_day_overrides where business_date=p_date;
 perform spa_private.audit('business_hours.override_deleted',p_date::text);
end $$;

create or replace function public.spa_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'settings',(select to_jsonb(s) from public.spa_settings s),'business',(select value from public.spa_business_settings where key='business'),'website',(select value from public.spa_business_settings where key='website'),
 'business_hours',coalesce((select jsonb_agg(to_jsonb(h) order by weekday) from public.spa_business_hours h),'[]'),
 'today_hours',(select to_jsonb(w) from spa_private.business_window((now() at time zone 'Asia/Taipei')::date) w),
 'services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s where active and status='active' and online_booking_enabled),'[]'),
 'website_services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s where active and status='active' and website_visible),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'name_en',name_en,'title',title,'specialty',specialty,'bio',bio,'photo_url',photo_url) order by display_order) from public.spa_staff where active and archived_at is null and is_bookable),'[]'),
 'website_staff',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'name_en',name_en,'title',title,'specialty',specialty,'bio',bio,'photo_url',photo_url) order by display_order) from public.spa_staff where active and archived_at is null and website_visible),'[]'),
 'skills',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_staff_services s where enabled),'[]'))
$$;

create or replace function public.spa_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; owner_view boolean:=spa_private.role_name()='owner';
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object('date',today,'appointments',(select count(*) from public.spa_appointments where business_date=today),'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',case when owner_view then coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.business_date=today and ch.refunded_at is null),0) end,
  'staff_working',(select count(distinct sh.staff_id) from public.spa_shifts sh join public.spa_staff s on s.id=sh.staff_id where sh.weekday=extract(dow from today)::int and s.active and s.archived_at is null),'rooms_active',(select count(*) from public.spa_rooms where active),
  'new_members',case when owner_view then (select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today) end,
  'low_stock',case when owner_view then (select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold) end,
  'today_hours',(select to_jsonb(w) from spa_private.business_window(today) w),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,c.name customer_name,s.name staff_name,r.name resource_name from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

create or replace function public.spa_settings_os() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 return jsonb_build_object('business',coalesce((select value from public.spa_business_settings where key='business'),'{}'),'website',coalesce((select value from public.spa_business_settings where key='website'),'{}'),'inventory',coalesce((select value from public.spa_business_settings where key='inventory'),'{}'),'assignment',coalesce((select value from public.spa_business_settings where key='assignment'),'{}'),'booking',(select to_jsonb(s) from public.spa_settings s),'resources',coalesce((select jsonb_agg(to_jsonb(r) order by name) from public.spa_rooms r),'[]'),
  'business_hours',coalesce((select jsonb_agg(to_jsonb(h) order by weekday) from public.spa_business_hours h),'[]'),
  'business_overrides',coalesce((select jsonb_agg(to_jsonb(o) order by business_date) from public.spa_business_day_overrides o where business_date>=(now() at time zone 'Asia/Taipei')::date and business_date<(now() at time zone 'Asia/Taipei')::date+180),'[]'));
end $$;

create or replace function spa_private.reset_bounds(p_from date,p_to date) returns table(first_time timestamptz,last_time timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if (p_from is null)<>(p_to is null) or (p_from is not null and p_to<p_from) or (p_from is not null and p_to-p_from>3660) then raise exception 'INVALID_DATE'; end if;
 first_time:=case when p_from is null then '-infinity'::timestamptz else p_from::timestamp at time zone 'Asia/Taipei' end;
 last_time:=case when p_to is null then 'infinity'::timestamptz else (p_to+1)::timestamp at time zone 'Asia/Taipei' end; return next;
end $$;

create or replace function public.spa_reset_preview(p_scope text,p_from date default null,p_to date default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b record;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'INVALID_INPUT'; end if;
 select * into b from spa_private.reset_bounds(p_from,p_to);
 return jsonb_build_object('scope',p_scope,'from',p_from,'to',p_to,'counts',jsonb_build_object(
  'appointments',case when p_scope in ('appointments','all') then (select count(*) from public.spa_appointments where p_from is null or business_date between p_from and p_to) else 0 end,
  'orders',case when p_scope in ('orders','all') then (select count(*) from public.spa_orders where coalesce(paid_at,created_at)>=b.first_time and coalesce(paid_at,created_at)<b.last_time) else 0 end,
  'reviews',case when p_scope='appointments' then (select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where p_from is null or a.business_date between p_from and p_to) when p_scope in ('reviews','all') then (select count(*) from public.spa_reviews where created_at>=b.first_time and created_at<b.last_time) else 0 end,
  'feedback',case when p_scope in ('reviews','all') then (select count(*) from public.spa_feedback where created_at>=b.first_time and created_at<b.last_time) else 0 end,
  'payroll_runs',case when p_scope in ('payroll','all') then (select count(*) from public.spa_payroll_runs where p_from is null or (period_start<=p_to and period_end>=p_from)) else 0 end,
  'time_entries',case when p_scope in ('payroll','all') then (select count(*) from public.spa_time_entries where p_from is null or work_date between p_from and p_to)+(select count(*) from public.spa_overtime_entries where p_from is null or work_date between p_from and p_to)+(select count(*) from public.spa_payroll_adjustments where p_from is null or period_start between p_from and p_to) else 0 end,
  'expenses',case when p_scope in ('expenses','all') then (select count(*) from public.spa_cash_entries where category='expense' and created_at>=b.first_time and created_at<b.last_time) else 0 end),
  'preserved',jsonb_build_array('會員檔案與儲值／套票購買記錄（預約扣用隨預約回滾）','員工與登入帳號','療程、商品與庫存主資料','門店與系統設定'));
end $$;

create or replace function public.spa_backup_export(p_scope text,p_from date default null,p_to date default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b record;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'INVALID_INPUT'; end if; select * into b from spa_private.reset_bounds(p_from,p_to);
 return jsonb_build_object('exported_at',now(),'scope',p_scope,'from',p_from,'to',p_to,'preview',public.spa_reset_preview(p_scope,p_from,p_to),
  'appointments',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_appointments a where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'checkouts',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(ch)) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_reviews',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_wallet_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_wallet_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_package_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_package_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_cash_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'booking_actions',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_booking_actions e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'orders',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_order_items i where i.order_id=o.id))) from public.spa_orders o where coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_inventory_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(i)) from public.spa_inventory_entries i join public.spa_orders o on o.id=i.reference_id where i.reference_type='order' and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_cash_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_orders o on o.request_id=e.request_id where e.category='product' and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'reviews',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r where r.created_at>=b.first_time and r.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'feedback',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(f)) from public.spa_feedback f where f.created_at>=b.first_time and f.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'payroll_runs',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_payroll_items i where i.run_id=r.id))) from public.spa_payroll_runs r where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'time_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_time_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'overtime_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_overtime_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'payroll_adjustments',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_payroll_adjustments e where p_from is null or e.period_start between p_from and p_to),'[]') else '[]'::jsonb end,
  'expenses',case when p_scope in ('expenses','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e where e.category='expense' and e.created_at>=b.first_time and e.created_at<b.last_time),'[]') else '[]'::jsonb end);
end $$;

create or replace function public.spa_reset_business_data(p_scope text,p_from date default null,p_to date default null,p_confirmation text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare b record; result jsonb; appointment_ids uuid[]; order_ids uuid[]; order_requests uuid[]; deleted_count int:=0;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_confirmation<>'RESET' or p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'RESET_CONFIRMATION_REQUIRED'; end if;
 perform pg_advisory_xact_lock(726099); select * into b from spa_private.reset_bounds(p_from,p_to); result:=public.spa_reset_preview(p_scope,p_from,p_to);
 if p_scope in ('appointments','all') then
  select coalesce(array_agg(id),'{}'::uuid[]) into appointment_ids from public.spa_appointments where p_from is null or business_date between p_from and p_to;
  if pg_catalog.to_regclass('public.spa_legacy_imports') is not null then execute 'update public.spa_legacy_imports set appointment_id=null where appointment_id=any($1)' using appointment_ids; end if;
  delete from public.spa_booking_actions where appointment_id=any(appointment_ids); delete from public.spa_booking_access where appointment_id=any(appointment_ids);
  delete from public.spa_reviews where appointment_id=any(appointment_ids); delete from public.spa_package_entries where appointment_id=any(appointment_ids);
  delete from public.spa_wallet_entries where appointment_id=any(appointment_ids); delete from public.spa_cash_entries where appointment_id=any(appointment_ids);
  delete from public.spa_checkouts where appointment_id=any(appointment_ids); delete from public.spa_appointments where id=any(appointment_ids); get diagnostics deleted_count=row_count;
 end if;
 if p_scope='reviews' then delete from public.spa_reviews where created_at>=b.first_time and created_at<b.last_time; end if;
 if p_scope in ('reviews','all') then delete from public.spa_feedback where created_at>=b.first_time and created_at<b.last_time; end if;
 if p_scope in ('orders','all') then
  select coalesce(array_agg(id),'{}'::uuid[]),coalesce(array_agg(request_id),'{}'::uuid[]) into order_ids,order_requests from public.spa_orders where coalesce(paid_at,created_at)>=b.first_time and coalesce(paid_at,created_at)<b.last_time;
  delete from public.spa_inventory_entries where reference_type='order' and reference_id=any(order_ids); delete from public.spa_cash_entries where category='product' and request_id=any(order_requests); delete from public.spa_orders where id=any(order_ids);
 end if;
 if p_scope in ('payroll','all') then
  delete from public.spa_payroll_runs where p_from is null or (period_start<=p_to and period_end>=p_from); delete from public.spa_time_entries where p_from is null or work_date between p_from and p_to;
  delete from public.spa_overtime_entries where p_from is null or work_date between p_from and p_to; delete from public.spa_payroll_adjustments where p_from is null or period_start between p_from and p_to;
 end if;
 if p_scope in ('expenses','all') then delete from public.spa_cash_entries where category='expense' and created_at>=b.first_time and created_at<b.last_time; end if;
 perform spa_private.audit('business_data.reset',p_scope,jsonb_build_object('from',p_from,'to',p_to,'preview',result)); return result||jsonb_build_object('reset_at',now());
end $$;

alter table public.spa_business_hours enable row level security;
alter table public.spa_business_day_overrides enable row level security;
revoke all on public.spa_business_hours,public.spa_business_day_overrides from public,anon,authenticated;
grant all on public.spa_business_hours,public.spa_business_day_overrides to service_role;
revoke all on function spa_private.business_window(date),spa_private.reset_bounds(date,date) from public,anon,authenticated;
grant execute on function spa_private.business_window(date),spa_private.reset_bounds(date,date) to service_role;
revoke all on function public.spa_business_hours_save(jsonb),public.spa_business_day_override_save(date,boolean,int,int,text),public.spa_business_day_override_delete(date),public.spa_reset_preview(text,date,date),public.spa_backup_export(text,date,date),public.spa_reset_business_data(text,date,date,text),public.spa_customer_save_v2(uuid,text,text,text,text,text,text,uuid),public.spa_customer_delete(uuid,text),public.spa_customer_restore(uuid) from public,anon,authenticated;
grant execute on function public.spa_business_hours_save(jsonb),public.spa_business_day_override_save(date,boolean,int,int,text),public.spa_business_day_override_delete(date),public.spa_reset_preview(text,date,date),public.spa_backup_export(text,date,date),public.spa_reset_business_data(text,date,date,text),public.spa_customer_save_v2(uuid,text,text,text,text,text,text,uuid),public.spa_customer_delete(uuid,text),public.spa_customer_restore(uuid) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
