begin;
create schema if not exists spa_private;
revoke all on schema spa_private from public;
grant usage on schema spa_private to authenticated;

create table public.spa_settings (
 id boolean primary key default true check(id), timezone text not null default 'Asia/Taipei' check(timezone='Asia/Taipei'),
 currency text not null default 'TWD' check(currency='TWD'), opening_minute int not null default 600,
 closing_minute int not null default 1560, slot_minutes int not null default 30,
 booking_days int not null default 30 check(booking_days between 1 and 180),
 auto_confirm boolean not null default false, cancellation_hours int not null default 24 check(cancellation_hours>=0),
 check(opening_minute>=0 and closing_minute>opening_minute and closing_minute<=2880), check(slot_minutes between 5 and 120)
);
insert into public.spa_settings(id) values(true);
create table public.spa_staff (
 id uuid primary key default gen_random_uuid(), name text not null check(length(btrim(name)) between 1 and 80),
 name_en text not null default '', title text not null default '調理師', specialty text not null default '',
 bio text not null default '', active boolean not null default true, commission_bps int not null default 0 check(commission_bps between 0 and 10000),
 display_order int not null default 0, created_at timestamptz not null default now()
);
create table public.spa_roles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 role text not null check(role in ('owner','manager','receptionist','therapist')),
 staff_id uuid references public.spa_staff, active boolean not null default true,
 check(role<>'therapist' or staff_id is not null)
);
create table public.spa_services (
 id uuid primary key default gen_random_uuid(), code text unique not null, name text not null, name_en text not null default '',
 duration_minutes int not null check(duration_minutes between 15 and 480), buffer_minutes int not null default 15 check(buffer_minutes between 0 and 120),
 price_cents bigint not null check(price_cents>=0), active boolean not null default true, display_order int not null default 0
);
create table public.spa_staff_services (
 staff_id uuid references public.spa_staff, service_id uuid references public.spa_services, primary key(staff_id,service_id)
);
create table public.spa_rooms (id uuid primary key default gen_random_uuid(), name text not null unique, active boolean not null default true);
create table public.spa_shifts (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.spa_staff,
 weekday int not null check(weekday between 0 and 6), start_minute int not null default 600,
 end_minute int not null default 1560, unique(staff_id,weekday), check(start_minute>=0 and end_minute>start_minute and end_minute<=2880)
);
create table public.spa_time_off (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.spa_staff,
 starts_at timestamptz not null, ends_at timestamptz not null, reason text not null default '', check(ends_at>starts_at)
);
create table public.spa_customers (
 id uuid primary key default gen_random_uuid(), auth_user_id uuid unique references auth.users(id) on delete set null,
 name text not null check(length(btrim(name)) between 1 and 80), phone text unique not null check(phone ~ '^\+?[0-9]{8,15}$'),
 email text not null default '', tier text not null default '一般會員', notes text not null default '',
 created_at timestamptz not null default now()
);
create table public.spa_appointments (
 id uuid primary key default gen_random_uuid(), reference text not null unique default ('ROU-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
 request_id uuid unique not null, customer_id uuid not null references public.spa_customers,
 staff_id uuid not null references public.spa_staff, room_id uuid not null references public.spa_rooms,
 service_id uuid not null references public.spa_services,
 business_date date not null, starts_at timestamptz not null, ends_at timestamptz not null, blocked_until timestamptz not null,
 status text not null default 'pending' check(status in ('pending','confirmed','checked_in','completed','cancelled','no_show')),
 service_name text not null, price_cents bigint not null check(price_cents>=0), tea_code int not null default 0 check(tea_code between 0 and 4),
 tea_cents bigint not null default 0 check(tea_cents>=0), note text not null default '', cancellation_reason text,
 manage_token uuid not null default gen_random_uuid(), review_token uuid not null default gen_random_uuid(),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(ends_at>starts_at and blocked_until>=ends_at)
);
create index spa_appointments_staff_time on public.spa_appointments(staff_id,starts_at,blocked_until);
create index spa_appointments_room_time on public.spa_appointments(room_id,starts_at,blocked_until);
create index spa_appointments_date on public.spa_appointments(business_date,status);
create index spa_appointments_customer on public.spa_appointments(customer_id,starts_at desc);
create table public.spa_wallet_entries (
 id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.spa_customers,
 amount_cents bigint not null check(amount_cents<>0), kind text not null check(kind in ('topup','redemption','refund','adjustment')),
 appointment_id uuid references public.spa_appointments, request_id uuid unique not null,
 note text not null, created_by uuid references auth.users, created_at timestamptz not null default now()
);
create index spa_wallet_customer on public.spa_wallet_entries(customer_id);
create table public.spa_packages (
 id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.spa_customers,
 service_id uuid not null references public.spa_services, name text not null,
 sessions int not null check(sessions between 1 and 200), paid_cents bigint not null check(paid_cents>=0),
 expires_at timestamptz not null, request_id uuid unique not null, created_at timestamptz not null default now()
);
create table public.spa_package_entries (
 id uuid primary key default gen_random_uuid(), package_id uuid not null references public.spa_packages,
 appointment_id uuid not null references public.spa_appointments, delta int not null check(delta in (-1,1)),
 created_at timestamptz not null default now(), unique(appointment_id,delta)
);
create table public.spa_checkouts (
 id uuid primary key default gen_random_uuid(), appointment_id uuid unique not null references public.spa_appointments,
 request_id uuid unique not null, gross_cents bigint not null, discount_cents bigint not null default 0,
 revenue_cents bigint not null, cash_cents bigint not null, wallet_cents bigint not null, tip_cents bigint not null default 0,
 package_id uuid references public.spa_packages, method text not null check(method in ('cash','card','transfer')),
 commission_cents bigint not null default 0, created_by uuid not null references auth.users,
 refunded_at timestamptz, refund_reason text, created_at timestamptz not null default now(),
 check(gross_cents>=0 and discount_cents>=0 and revenue_cents>=0 and cash_cents>=0 and wallet_cents>=0 and tip_cents>=0),
 check(discount_cents<=gross_cents)
);
create table public.spa_cash_entries (
 id uuid primary key default gen_random_uuid(), request_id uuid not null,
 customer_id uuid references public.spa_customers, appointment_id uuid references public.spa_appointments,
 amount_cents bigint not null check(amount_cents<>0), category text not null check(category in ('service','topup','package','tip','expense','refund')),
 method text not null check(method in ('cash','card','transfer')), note text not null default '',
 created_by uuid not null references auth.users, created_at timestamptz not null default now(), unique(request_id,category)
);
create index spa_cash_date on public.spa_cash_entries(created_at);
create table public.spa_reviews (
 id uuid primary key default gen_random_uuid(), appointment_id uuid unique not null references public.spa_appointments,
 rating int not null check(rating between 1 and 5), comment text not null check(length(comment)<=1000),
 status text not null default 'pending' check(status in ('pending','published','hidden')), reply text not null default '',
 created_at timestamptz not null default now()
);
create table public.spa_feedback (
 id uuid primary key default gen_random_uuid(), message text not null check(length(btrim(message)) between 5 and 500),
 status text not null default 'unread' check(status in ('unread','read','resolved')), created_at timestamptz not null default now()
);
create table public.spa_audit (
 id bigint generated always as identity primary key, actor uuid, action text not null, entity_id text,
 detail jsonb not null default '{}', created_at timestamptz not null default now()
);

-- Internal authorization is independent from client-side UI and editable user metadata.
create function spa_private.role_name() returns text language sql stable security definer set search_path='' as $$
 select role from public.spa_roles where user_id=auth.uid() and active
$$;
create function spa_private.require_role(allowed text[]) returns void language plpgsql security definer set search_path='' as $$
begin
 if coalesce(spa_private.role_name()=any(allowed),false)=false then raise exception 'FORBIDDEN' using errcode='42501'; end if;
end $$;
create function spa_private.audit(p_action text,p_entity text,p_detail jsonb default '{}') returns void language sql security definer set search_path='' as $$
 insert into public.spa_audit(actor,action,entity_id,detail) values(auth.uid(),p_action,p_entity,p_detail)
$$;
create function spa_private.phone(p_phone text) returns text language sql immutable set search_path='' as $$
 select regexp_replace(btrim(p_phone),'[[:space:]()-]','','g')
$$;

-- A shared transaction lock protects allocation against booking, rescheduling and time-off races.
-- Trigger provides the same invariant for privileged imports/direct database writes.
create function spa_private.guard_appointment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(726001);
 if new.status in ('pending','confirmed','checked_in','completed') then
  if exists(select 1 from public.spa_appointments a where a.id<>new.id and a.status in ('pending','confirmed','checked_in','completed')
    and (a.staff_id=new.staff_id or a.room_id=new.room_id) and a.starts_at<new.blocked_until and a.blocked_until>new.starts_at) then
   raise exception 'SLOT_TAKEN' using errcode='23P01';
  end if;
 end if;
 new.updated_at=now(); return new;
end $$;
create trigger spa_appointment_guard before insert or update on public.spa_appointments for each row execute function spa_private.guard_appointment();

create function public.spa_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'settings',(select to_jsonb(s) from public.spa_settings s),
 'services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s where active),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'name_en',name_en,'title',title,'specialty',specialty,'bio',bio) order by display_order) from public.spa_staff where active),'[]'),
 'skills',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_staff_services s),'[]'))
$$;
create function spa_private.candidates(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
 returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
 language sql stable security definer set search_path='' as $$
 with settings as (select * from public.spa_settings), service as (select * from public.spa_services where id=p_service and active),
 timing as (select p_start+make_interval(mins=>s.duration_minutes) finish,p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s)
 select st.id,r.id,t.finish,t.blocked from public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service
 join public.spa_shifts sh on sh.staff_id=st.id and sh.weekday=extract(dow from p_date)::int
 cross join public.spa_rooms r cross join settings cfg cross join timing t
 where st.active and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(cfg.opening_minute,sh.start_minute))) at time zone cfg.timezone)
 and t.blocked<=((p_date::timestamp+make_interval(mins=>least(cfg.closing_minute,sh.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','completed') and (a.staff_id=st.id or a.room_id=r.id) and a.starts_at<t.blocked and a.blocked_until>p_start)
 order by (select count(*) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),st.display_order,r.name
$$;
create function public.spa_availability(p_service uuid,p_date date,p_staff uuid default null)
 returns table(time_label text,starts_at timestamptz,available boolean) language plpgsql stable security definer set search_path='' as $$
declare cfg public.spa_settings; minute int; start_at timestamptz;
begin
 select * into cfg from public.spa_settings;
 if p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days then return; end if;
 for minute in select generate_series(cfg.opening_minute,cfg.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI');
  starts_at:=start_at;
  available:=start_at>now()+interval '30 minutes' and exists(select 1 from spa_private.candidates(p_service,p_date,start_at,p_staff));
  return next;
 end loop;
end $$;
create function public.spa_create_booking(p_request uuid,p_service uuid,p_date date,p_start timestamptz,p_staff uuid,p_name text,p_phone text,p_tea int default 0,p_note text default '')
 returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; svc public.spa_services; slot record; customer uuid; booking public.spa_appointments; tel text; minute int;
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
 select * into svc from public.spa_services where id=p_service and active;
 if not found then raise exception 'INVALID_SERVICE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or p_date<(now() at time zone cfg.timezone)::date or p_date>(now() at time zone cfg.timezone)::date+cfg.booking_days or p_start<=now()+interval '30 minutes' or minute<cfg.opening_minute or minute>=cfg.closing_minute or (minute-cfg.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 select id into customer from public.spa_customers where phone=tel;
 if customer is not null and (select count(*) from public.spa_appointments where customer_id=customer and created_at>now()-interval '24 hours')>=5 then raise exception 'RATE_LIMIT'; end if;
 select * into slot from spa_private.candidates(p_service,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 -- Public bookings never overwrite an existing member profile.
 if customer is null then insert into public.spa_customers(name,phone) values(btrim(p_name),tel) returning id into customer; end if;
 insert into public.spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note)
 values(p_request,customer,slot.staff_id,slot.room_id,p_service,p_date,p_start,slot.ends_at,slot.blocked_until,case when cfg.auto_confirm then 'confirmed' else 'pending' end,svc.name,svc.price_cents,p_tea,(array[0,12000,15000,12000,18000])[p_tea+1],coalesce(p_note,'')) returning * into booking;
 perform spa_private.audit('booking.created',booking.id::text,jsonb_build_object('source','website'));
 return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token);
end $$;

create function public.spa_session() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('role',spa_private.role_name(),'staff_id',(select staff_id from public.spa_roles where user_id=auth.uid() and active),'customer_id',(select id from public.spa_customers where auth_user_id=auth.uid()))
$$;
create function public.spa_admin_bookings(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist','therapist']);
 if p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('customer_name',c.name,'phone',c.phone,'therapist',s.name,'room',r.name,'checkout',to_jsonb(ch)) order by a.starts_at)
 from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id left join public.spa_checkouts ch on ch.appointment_id=a.id
 where a.business_date between p_from and p_to and (spa_private.role_name()<>'therapist' or a.staff_id=(select staff_id from public.spa_roles where user_id=auth.uid()))),'[]');
end $$;
create function public.spa_set_status(p_id uuid,p_status text,p_reason text default '') returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments;
begin
 perform spa_private.require_role(array['owner','manager','receptionist','therapist']);
 perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if spa_private.role_name()='therapist' and (p_status<>'completed' or a.staff_id<>(select staff_id from public.spa_roles where user_id=auth.uid())) then raise exception 'FORBIDDEN'; end if;
 if not ((a.status='pending' and p_status in ('confirmed','cancelled')) or (a.status='confirmed' and p_status in ('checked_in','cancelled','no_show')) or (a.status='checked_in' and p_status='completed')) then raise exception 'INVALID_TRANSITION'; end if;
 if p_status in ('cancelled','no_show') and length(btrim(p_reason))=0 then raise exception 'REASON_REQUIRED'; end if;
 if p_status in ('checked_in','completed','no_show') and a.starts_at>now() then raise exception 'TOO_EARLY'; end if;
 update public.spa_appointments set status=p_status,cancellation_reason=case when p_status in ('cancelled','no_show') then p_reason else cancellation_reason end where id=p_id;
 perform spa_private.audit('booking.'||p_status,p_id::text,jsonb_build_object('reason',p_reason));
end $$;
create function public.spa_reschedule(p_id uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; slot record;
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed') or length(btrim(p_reason))=0 then raise exception 'INVALID_TRANSITION'; end if;
 -- Release old interval inside this transaction only; any failure rolls it back.
 update public.spa_appointments set status='cancelled' where id=p_id;
 if not exists(select 1 from public.spa_availability(a.service_id,p_date,p_staff) av where av.starts_at=p_start and av.available) then raise exception 'SLOT_TAKEN'; end if;
 select * into slot from spa_private.candidates(a.service_id,p_date,p_start,p_staff) limit 1;
 update public.spa_appointments set business_date=p_date,starts_at=p_start,ends_at=slot.ends_at,blocked_until=slot.blocked_until,staff_id=slot.staff_id,room_id=slot.room_id,status=a.status where id=p_id;
 perform spa_private.audit('booking.rescheduled',p_id::text,jsonb_build_object('old_start',a.starts_at,'new_start',p_start,'reason',p_reason));
end $$;

create function public.spa_customers_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 return coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('balance_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries where customer_id=c.id),0),'visits',(select count(*) from public.spa_appointments where customer_id=c.id and status='completed'),'last_visit',(select max(starts_at) from public.spa_appointments where customer_id=c.id and status='completed')) order by c.created_at desc) from public.spa_customers c),'[]');
end $$;
create function public.spa_customer_save(p_id uuid,p_name text,p_phone text,p_email text,p_tier text,p_notes text,p_user uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 if p_user is not null then perform spa_private.require_role(array['owner','manager']); end if;
 if length(coalesce(p_notes,''))>4000 or length(coalesce(p_email,''))>254 then raise exception 'INVALID_INPUT'; end if;
 if p_id is null then insert into public.spa_customers(name,phone,email,tier,notes,auth_user_id) values(btrim(p_name),spa_private.phone(p_phone),coalesce(p_email,''),coalesce(p_tier,'一般會員'),coalesce(p_notes,''),p_user) returning id into result;
 else update public.spa_customers set name=btrim(p_name),phone=spa_private.phone(p_phone),email=coalesce(p_email,''),tier=coalesce(p_tier,'一般會員'),notes=coalesce(p_notes,''),auth_user_id=case when spa_private.role_name() in ('owner','manager') then p_user else auth_user_id end where id=p_id returning id into result;
 end if;
 if result is null then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('customer.saved',result::text); return result;
end $$;
create function public.spa_customer_detail(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.spa_customers where id=p_customer and auth_user_id=auth.uid()) then perform spa_private.require_role(array['owner','manager','receptionist']); end if;
 return jsonb_build_object('wallet',coalesce((select jsonb_agg(to_jsonb(w) order by created_at desc) from public.spa_wallet_entries w where customer_id=p_customer),'[]'),
 'packages',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('remaining',p.sessions+coalesce((select sum(delta) from public.spa_package_entries where package_id=p.id),0),'service_name',s.name)) from public.spa_packages p join public.spa_services s on s.id=p.service_id where p.customer_id=p_customer),'[]'),
 'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'reference',a.reference,'service_name',a.service_name,'starts_at',a.starts_at,'status',a.status,'review_token',case when a.status='completed' then a.review_token end,'manage_token',a.manage_token) order by a.starts_at desc) from public.spa_appointments a where a.customer_id=p_customer),'[]'));
end $$;
create function public.spa_topup(p_request uuid,p_customer uuid,p_cents bigint,p_method text,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_cents is null or p_cents<=0 or p_cents>100000000 or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_wallet_entries where request_id=p_request) then return; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'topup',p_request,p_note,auth.uid());
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'topup',p_method,p_note,auth.uid());
 perform spa_private.audit('wallet.topup',p_customer::text,jsonb_build_object('cents',p_cents));
end $$;
create function public.spa_wallet_adjust(p_request uuid,p_customer uuid,p_cents bigint,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare balance bigint;
begin
 perform spa_private.require_role(array['owner','manager']);
 perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_cents is null or p_cents=0 or abs(p_cents)>100000000 or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_wallet_entries where request_id=p_request) then return; end if;
 select coalesce(sum(amount_cents),0) into balance from public.spa_wallet_entries where customer_id=p_customer;
 if balance+p_cents<0 then raise exception 'INSUFFICIENT_CREDITS'; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'adjustment',p_request,p_note,auth.uid());
 perform spa_private.audit('wallet.adjusted',p_customer::text,jsonb_build_object('cents',p_cents,'reason',p_note));
end $$;
create function public.spa_package_sell(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_expires is null or p_expires<=now() or p_cents is null or p_cents<=0 or p_cents>100000000 or length(btrim(p_name))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_packages where request_id=p_request) then return; end if;
 insert into public.spa_packages(customer_id,service_id,name,sessions,paid_cents,expires_at,request_id) values(p_customer,p_service,p_name,p_sessions,p_cents,p_expires,p_request);
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'package',p_method,p_name,auth.uid());
 perform spa_private.audit('package.sold',p_customer::text,jsonb_build_object('sessions',p_sessions,'cents',p_cents));
end $$;

create function public.spa_checkout(p_request uuid,p_appointment uuid,p_discount bigint,p_wallet bigint,p_package uuid,p_tip bigint,p_method text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; pkg public.spa_packages; gross bigint; due bigint; balance bigint; cash bigint; revenue bigint; used int; commission bigint; result public.spa_checkouts;
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 select * into result from public.spa_checkouts where request_id=p_request;
 if found then
  if result.appointment_id<>p_appointment then raise exception 'REQUEST_CONFLICT'; end if;
  return to_jsonb(result);
 end if;
 if a.status<>'completed' or exists(select 1 from public.spa_checkouts where appointment_id=a.id) then raise exception 'INVALID_TRANSITION'; end if;
 if p_discount is null or p_wallet is null or p_tip is null or p_discount<0 or p_wallet<0 or p_tip<0 or p_tip>100000000 then raise exception 'INVALID_INPUT'; end if;
 perform 1 from public.spa_customers where id=a.customer_id for update;
 gross:=a.price_cents+a.tea_cents;
 if p_package is not null then
  select * into pkg from public.spa_packages where id=p_package for update;
  if not found or pkg.customer_id<>a.customer_id or pkg.service_id<>a.service_id or pkg.expires_at<=now() or p_discount<>0 then raise exception 'INVALID_PACKAGE'; end if;
  select -coalesce(sum(delta),0) into used from public.spa_package_entries where package_id=p_package;
  if used>=pkg.sessions then raise exception 'INSUFFICIENT_CREDITS'; end if;
  due:=a.tea_cents;
  revenue:=case when used=pkg.sessions-1 then pkg.paid_cents-coalesce((select sum(ch.revenue_cents-ap.tea_cents) from public.spa_checkouts ch join public.spa_appointments ap on ap.id=ch.appointment_id where ch.package_id=pkg.id and ch.refunded_at is null),0) else pkg.paid_cents/pkg.sessions end+a.tea_cents;
  insert into public.spa_package_entries(package_id,appointment_id,delta) values(p_package,a.id,-1);
 else
  if p_discount>gross then raise exception 'INVALID_INPUT'; end if;
  if p_discount>0 then perform spa_private.require_role(array['owner','manager']); end if;
  due:=gross-p_discount; revenue:=due;
 end if;
 select coalesce(sum(amount_cents),0) into balance from public.spa_wallet_entries where customer_id=a.customer_id;
 if p_wallet>balance or p_wallet>due then raise exception 'INSUFFICIENT_CREDITS'; end if;
 cash:=due-p_wallet;
 if p_wallet>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,-p_wallet,'redemption',a.id,p_request,'療程結帳 '||a.reference,auth.uid()); end if;
 if cash>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,cash,'service',p_method,a.reference,auth.uid()); end if;
 if p_tip>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,p_tip,'tip',p_method,a.reference,auth.uid()); end if;
 select round(greatest(0,revenue-a.tea_cents)*commission_bps/10000.0) into commission from public.spa_staff where id=a.staff_id;
 insert into public.spa_checkouts(appointment_id,request_id,gross_cents,discount_cents,revenue_cents,cash_cents,wallet_cents,tip_cents,package_id,method,commission_cents,created_by)
 values(a.id,p_request,gross,p_discount,revenue,cash,p_wallet,p_tip,p_package,p_method,commission,auth.uid()) returning * into result;
 perform spa_private.audit('checkout.completed',a.id::text,jsonb_build_object('revenue_cents',revenue,'cash_cents',cash));
 return to_jsonb(result);
end $$;
create function public.spa_refund(p_request uuid,p_appointment uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; ch public.spa_checkouts;
begin
 perform spa_private.require_role(array['owner','manager']);
 select * into a from public.spa_appointments where id=p_appointment for update;
 select * into ch from public.spa_checkouts where appointment_id=p_appointment for update;
 if not found or length(btrim(p_reason))=0 then raise exception 'INVALID_INPUT'; end if;
 if ch.refunded_at is not null then return; end if;
 perform 1 from public.spa_customers where id=a.customer_id for update;
 if ch.wallet_cents>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,ch.wallet_cents,'refund',a.id,p_request,p_reason,auth.uid()); end if;
 if ch.package_id is not null then insert into public.spa_package_entries(package_id,appointment_id,delta) values(ch.package_id,a.id,1); end if;
 if ch.cash_cents+ch.tip_cents>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,-ch.cash_cents-ch.tip_cents,'refund',ch.method,p_reason,auth.uid()); end if;
 update public.spa_checkouts set refunded_at=now(),refund_reason=p_reason where id=ch.id;
 perform spa_private.audit('checkout.refunded',a.id::text,jsonb_build_object('reason',p_reason));
end $$;
create function public.spa_expense(p_request uuid,p_cents bigint,p_method text,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 if p_cents is null or p_cents<=0 or p_cents>100000000 or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_cash_entries(request_id,amount_cents,category,method,note,created_by) values(p_request,-p_cents,'expense',p_method,p_note,auth.uid()) on conflict(request_id,category) do nothing;
 perform spa_private.audit('expense.recorded',p_request::text,jsonb_build_object('cents',p_cents,'note',p_note));
end $$;

create function public.spa_manage_booking(p_token uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('reference',reference,'status',status,'service_name',service_name,'starts_at',starts_at,'ends_at',ends_at,'price_cents',price_cents+tea_cents) from public.spa_appointments where manage_token=p_token
$$;
create function public.spa_cancel_booking(p_token uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; hours int;
begin
 perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where manage_token=p_token for update;
 select cancellation_hours into hours from public.spa_settings;
 if not found or a.id is null then raise exception 'NOT_FOUND'; end if;
 if a.status='cancelled' then return; end if;
 if a.status not in ('pending','confirmed') or a.starts_at<now()+make_interval(hours=>hours) then raise exception 'CANCELLATION_CUTOFF'; end if;
 if length(btrim(p_reason))=0 then raise exception 'REASON_REQUIRED'; end if;
 update public.spa_appointments set status='cancelled',cancellation_reason=p_reason where id=a.id;
 perform spa_private.audit('booking.customer_cancelled',a.id::text,jsonb_build_object('reason',p_reason));
end $$;
create function public.spa_review_context(p_token uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('reference',a.reference,'service_name',a.service_name,'therapist',s.name,'submitted',exists(select 1 from public.spa_reviews where appointment_id=a.id)) from public.spa_appointments a join public.spa_staff s on s.id=a.staff_id where a.review_token=p_token and a.status='completed'
$$;
create function public.spa_submit_review(p_token uuid,p_rating int,p_comment text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments;
begin
 select * into a from public.spa_appointments where review_token=p_token and status='completed' for update;
 if not found then raise exception 'REVIEW_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>1000 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_reviews(appointment_id,rating,comment) values(a.id,p_rating,btrim(p_comment)) on conflict(appointment_id) do nothing;
end $$;
create function public.spa_submit_feedback(p_message text) returns void language plpgsql security definer set search_path='' as $$
begin
 if (select count(*) from public.spa_feedback where created_at>now()-interval '1 minute')>=20 then raise exception 'RATE_LIMIT'; end if;
 insert into public.spa_feedback(message) values(btrim(p_message));
end $$;
create function public.spa_public_reviews() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') from (select rv.rating,rv.comment,rv.reply,rv.created_at,st.name therapist from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id join public.spa_staff st on st.id=a.staff_id where rv.status='published' order by rv.created_at desc limit 20) r
$$;
create function public.spa_reviews_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 return jsonb_build_object('reviews',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('customer_name',c.name,'therapist',s.name,'reference',a.reference) order by r.created_at desc) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id),'[]'),'feedback',coalesce((select jsonb_agg(to_jsonb(f) order by created_at desc) from public.spa_feedback f),'[]'));
end $$;
create function public.spa_moderate(p_kind text,p_id uuid,p_status text,p_reply text default '') returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist']);
 if p_kind='review' and p_status in ('pending','published','hidden') and length(p_reply)<=1000 then update public.spa_reviews set status=p_status,reply=p_reply where id=p_id;
 elsif p_kind='feedback' and p_status in ('unread','read','resolved') then update public.spa_feedback set status=p_status where id=p_id;
 else raise exception 'INVALID_INPUT'; end if;
 if not found then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit(p_kind||'.moderated',p_id::text,jsonb_build_object('status',p_status));
end $$;

create function public.spa_team_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager','receptionist','therapist']);
 return jsonb_build_object('staff',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_staff s where spa_private.role_name()<>'therapist' or s.id=(select staff_id from public.spa_roles where user_id=auth.uid())),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s where spa_private.role_name()<>'therapist' or s.staff_id=(select staff_id from public.spa_roles where user_id=auth.uid())),'[]'),
 'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where ends_at>now()-interval '7 days' and (spa_private.role_name()<>'therapist' or t.staff_id=(select staff_id from public.spa_roles where user_id=auth.uid()))),'[]'),
 'rooms',coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_rooms r),'[]'),
 'roles',case when spa_private.role_name()='owner' then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_roles r),'[]') else '[]'::jsonb end);
end $$;
create function public.spa_staff_save(p_id uuid,p_name text,p_name_en text,p_title text,p_specialty text,p_bio text,p_commission int,p_active boolean,p_services uuid[]) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_role(array['owner','manager']);
 if p_id is null then insert into public.spa_staff(name,name_en,title,specialty,bio,commission_bps,active) values(p_name,p_name_en,p_title,p_specialty,p_bio,p_commission,p_active) returning id into result;
 else update public.spa_staff set name=p_name,name_en=p_name_en,title=p_title,specialty=p_specialty,bio=p_bio,commission_bps=p_commission,active=p_active where id=p_id returning id into result; end if;
 if result is null then raise exception 'NOT_FOUND'; end if;
 delete from public.spa_staff_services where staff_id=result;
 insert into public.spa_staff_services(staff_id,service_id) select result,unnest(p_services);
 perform spa_private.audit('staff.saved',result::text); return result;
end $$;
create function public.spa_shift_save(p_staff uuid,p_weekday int,p_start int,p_end int) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 perform pg_advisory_xact_lock(726001);
 insert into public.spa_shifts(staff_id,weekday,start_minute,end_minute) values(p_staff,p_weekday,p_start,p_end) on conflict(staff_id,weekday) do update set start_minute=excluded.start_minute,end_minute=excluded.end_minute;
 perform spa_private.audit('shift.saved',p_staff::text,jsonb_build_object('weekday',p_weekday));
end $$;
create function public.spa_time_off_save(p_staff uuid,p_start timestamptz,p_end timestamptz,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 perform pg_advisory_xact_lock(726001);
 if length(btrim(p_reason))=0 then raise exception 'REASON_REQUIRED'; end if;
 if exists(select 1 from public.spa_appointments where staff_id=p_staff and status in ('pending','confirmed','checked_in') and starts_at<p_end and blocked_until>p_start) then raise exception 'EXISTING_BOOKINGS'; end if;
 insert into public.spa_time_off(staff_id,starts_at,ends_at,reason) values(p_staff,p_start,p_end,p_reason);
 perform spa_private.audit('time_off.created',p_staff::text,jsonb_build_object('reason',p_reason));
end $$;
create function public.spa_time_off_delete(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 delete from public.spa_time_off where id=p_id;
 perform spa_private.audit('time_off.deleted',p_id::text);
end $$;
create function public.spa_role_save(p_user uuid,p_role text,p_staff uuid,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);
 perform pg_advisory_xact_lock(726002);
 if p_user=auth.uid() and (p_role<>'owner' or not p_active) then raise exception 'OWNER_SELF_CHANGE'; end if;
 insert into public.spa_roles(user_id,role,staff_id,active) values(p_user,p_role,p_staff,p_active) on conflict(user_id) do update set role=excluded.role,staff_id=excluded.staff_id,active=excluded.active;
 perform spa_private.audit('role.saved',p_user::text,jsonb_build_object('role',p_role,'active',p_active));
end $$;
create function public.spa_service_save(p_id uuid,p_name text,p_name_en text,p_minutes int,p_buffer int,p_cents bigint,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 update public.spa_services set name=p_name,name_en=p_name_en,duration_minutes=p_minutes,buffer_minutes=p_buffer,price_cents=p_cents,active=p_active where id=p_id;
 if not found then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('service.saved',p_id::text);
end $$;
create function public.spa_settings_save(p_open int,p_close int,p_days int,p_auto boolean,p_cancel int) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 update public.spa_settings set opening_minute=p_open,closing_minute=p_close,booking_days=p_days,auto_confirm=p_auto,cancellation_hours=p_cancel;
 perform spa_private.audit('settings.saved','store');
end $$;
create function public.spa_room_save(p_id uuid,p_name text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 if p_id is null then insert into public.spa_rooms(name,active) values(p_name,p_active);
 else update public.spa_rooms set name=p_name,active=p_active where id=p_id; if not found then raise exception 'NOT_FOUND'; end if; end if;
 perform spa_private.audit('room.saved',coalesce(p_id::text,p_name));
end $$;

create function public.spa_report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare first_time timestamptz; last_time timestamptz;
begin
 perform spa_private.require_role(array['owner','manager']);
 if p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 first_time:=p_from::timestamp at time zone 'Asia/Taipei'; last_time:=(p_to+1)::timestamp at time zone 'Asia/Taipei';
 return jsonb_build_object(
 'bookings',(select count(*) from public.spa_appointments where business_date between p_from and p_to),
 'completed',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='completed'),
 'cancelled',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='cancelled'),
 'no_show',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='no_show'),
 -- Refund is recognized on its actual date; historical sales do not silently disappear.
 'revenue_cents',coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0),
 'cash_in_cents',coalesce((select sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents>0),0),
 'cash_out_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents<0),0),
 'expenses_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and category='expense'),0),
 'wallet_liability_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries),0),
 'package_liability_cents',coalesce((select sum(p.paid_cents-coalesce((select sum(ch.revenue_cents-a.tea_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.package_id=p.id and ch.refunded_at is null),0)) from public.spa_packages p),0),
 'cash_entries',coalesce((select jsonb_agg(to_jsonb(e) order by created_at desc) from public.spa_cash_entries e where created_at>=first_time and created_at<last_time),'[]'),
 'daily',coalesce((select jsonb_agg(to_jsonb(d) order by date) from (select (created_at at time zone 'Asia/Taipei')::date date,sum(amount_cents) net_cents from public.spa_cash_entries where created_at>=first_time and created_at<last_time group by 1) d),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,
 'completed',(select count(*) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed'),
 'minutes',(select coalesce(sum(extract(epoch from (ends_at-starts_at))/60),0) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed'),
 'revenue_cents',(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time),
 'commission_cents',(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time),
 'rating',(select round(avg(rv.rating),2) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to),
 'reviews',(select count(*) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to))) from public.spa_staff s),'[]'),
 'audit',coalesce((select jsonb_agg(to_jsonb(a) order by created_at desc) from (select * from public.spa_audit where created_at>=first_time and created_at<last_time order by created_at desc limit 200) a),'[]'));
end $$;

-- No direct browser table access. Every public operation above has an explicit allow-list.
do $$ declare tbl record; fn record; begin
 for tbl in select tablename from pg_tables where schemaname='public' and tablename like 'spa_%' loop
  execute format('alter table public.%I enable row level security',tbl.tablename);
  execute format('revoke all on public.%I from public, anon, authenticated',tbl.tablename);
  execute format('grant all on public.%I to service_role',tbl.tablename);
 end loop;
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='public' and p.proname like 'spa_%') or n.nspname='spa_private' loop
  execute format('revoke all on function %s from public, anon, authenticated',fn.signature);
  execute format('grant execute on function %s to service_role',fn.signature);
 end loop;
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'spa_%' loop
  execute format('grant execute on function %s to authenticated',fn.signature);
 end loop;
end $$;
grant execute on function public.spa_catalog(),public.spa_availability(uuid,date,uuid),public.spa_create_booking(uuid,uuid,date,timestamptz,uuid,text,text,int,text),public.spa_manage_booking(uuid),public.spa_cancel_booking(uuid,text),public.spa_review_context(uuid),public.spa_submit_review(uuid,int,text),public.spa_submit_feedback(text),public.spa_public_reviews() to anon;

-- These are the CURRENT 45/90/120 minute offers from the existing website, not the obsolete i18n catalog.
insert into public.spa_services(code,name,name_en,duration_minutes,price_cents,display_order) values
 ('formula45','45分方子','45-minute therapy',45,110000,0),('formula90','90分方子','90-minute therapy',90,236000,1),('formula120','120分全息','120-minute therapy',120,320000,2);
insert into public.spa_staff(name,name_en,title,specialty,display_order) values
 ('林雅芳','Lin Ya-Fang','首席調理師','經絡調理 · 艾灸養生',0),('陳柏翰','Chen Bo-Han','資深調理師','草本頭療 · 刮痧排毒',1),('王詩涵','Wang Shi-Han','調理師','全息SPA · 肩頸調理',2),('張家豪','Zhang Jia-Hao','調理師','頭部推拿 · 穴位按摩',3),('李靜怡','Li Jing-Yi','調理師','芳香療法 · 淋巴排毒',4),('吳俊霖','Wu Jun-Lin','調理師','經絡推拿 · 拔罐理療',5);
insert into public.spa_staff_services select st.id,sv.id from public.spa_staff st cross join public.spa_services sv;
insert into public.spa_shifts(staff_id,weekday) select st.id,d from public.spa_staff st cross join generate_series(0,6) d;
-- Four treatment beds, confirmed by the owner.
insert into public.spa_rooms(name) values('床位 1'),('床位 2'),('床位 3'),('床位 4');
notify pgrst,'reload schema';
commit;
