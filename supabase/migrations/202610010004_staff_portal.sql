begin;
alter table public.spa_staff add column if not exists pay_basis text not null default 'monthly' check(pay_basis in ('monthly','hourly','session'));
alter table public.spa_staff add column if not exists base_pay_cents bigint check(base_pay_cents>=0);
alter table public.spa_staff add column if not exists archived_at timestamptz;
alter table public.spa_roles add column if not exists login_after timestamptz;
alter table public.spa_roles add column if not exists login_name text check(login_name is null or login_name ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
create unique index if not exists spa_roles_login_name on public.spa_roles(lower(login_name)) where login_name is not null;
create table if not exists public.spa_staff_login_limits(login_hash text primary key,window_start timestamptz not null,attempts int not null);
alter table public.spa_staff_login_limits enable row level security;
revoke all on public.spa_staff_login_limits from public,anon,authenticated;
grant all on public.spa_staff_login_limits to service_role;
create or replace function public.spa_session() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('role',spa_private.role_name(),'staff_id',(select staff_id from public.spa_roles where user_id=auth.uid() and active),
 'username',(select login_name from public.spa_roles where user_id=auth.uid() and active),'customer_id',(select id from public.spa_customers where auth_user_id=auth.uid()))
$$;

-- Existing people and owner accounts are preserved. Non-owner roles share a read-only workbench.
create or replace function spa_private.role_name() returns text language sql stable security definer set search_path='' as $$
 select r.role from public.spa_roles r where r.user_id=auth.uid() and r.active
 and (r.role='owner' or (r.login_after is null or to_timestamp(coalesce(nullif(auth.jwt()->>'iat',''),'0')::double precision)>=r.login_after))
 and (r.role='owner' or r.staff_id is null or exists(select 1 from public.spa_staff s where s.id=r.staff_id and s.archived_at is null))
$$;
create or replace function spa_private.require_role(allowed text[]) returns void language plpgsql security definer set search_path='' as $$
begin
 if spa_private.role_name() is distinct from 'owner' or not ('owner'=any(allowed)) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
end $$;
create or replace function spa_private.require_team() returns void language plpgsql stable security definer set search_path='' as $$
begin
 if spa_private.role_name() is null then raise exception 'FORBIDDEN' using errcode='42501'; end if;
end $$;

create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if spa_private.role_name()='owner' then
  return coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('customer_name',c.name,'phone',c.phone,'therapist',s.name,'room',r.name,'checkout',to_jsonb(ch)) order by a.starts_at)
   from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id left join public.spa_checkouts ch on ch.appointment_id=a.id where a.business_date between p_from and p_to),'[]');
 end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'reference',a.reference,'customer_id',a.customer_id,'customer_name',c.name,'phone',c.phone,
  'staff_id',a.staff_id,'therapist',s.name,'room',r.name,'service_name',a.service_name,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id where a.business_date between p_from and p_to),'[]');
end $$;
create or replace function public.spa_customers_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_team();
 return coalesce((select jsonb_agg((case when spa_private.role_name()='owner' then to_jsonb(c) else jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'tier',c.tier) end)
  ||jsonb_build_object('balance_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries where customer_id=c.id),0),
  'visits',(select count(*) from public.spa_appointments where customer_id=c.id and status='completed'),
  'last_visit',(select max(starts_at) from public.spa_appointments where customer_id=c.id and status='completed')) order by c.created_at desc) from public.spa_customers c),'[]');
end $$;
create or replace function public.spa_employee_customer(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_team();
 if not exists(select 1 from public.spa_customers where id=p_customer) then raise exception 'NOT_FOUND'; end if;
 return jsonb_build_object('packages',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'service_name',s.name,'sessions',p.sessions,'expires_at',p.expires_at,
  'remaining',p.sessions+coalesce((select sum(delta) from public.spa_package_entries where package_id=p.id),0))) from public.spa_packages p join public.spa_services s on s.id=p.service_id where p.customer_id=p_customer),'[]'));
end $$;
create or replace function public.spa_team_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);
 return jsonb_build_object('staff',coalesce((select jsonb_agg(to_jsonb(s) order by display_order,created_at) from public.spa_staff s),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s),'[]'),
 'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where ends_at>now()-interval '7 days'),'[]'),
 'rooms',coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_rooms r),'[]'),
 'roles',coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'role',r.role,'staff_id',r.staff_id,'active',r.active,'username',r.login_name,'email',case when r.role='owner' then u.email end)) from public.spa_roles r join auth.users u on u.id=r.user_id),'[]'));
end $$;
create or replace function public.spa_staff_profile_save(p_id uuid,p_name text,p_name_en text,p_title text,p_specialty text,p_bio text,p_commission int,p_active boolean,p_services uuid[],p_pay_basis text,p_base_pay bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_role(array['owner']);
 if p_pay_basis is null or p_pay_basis not in ('monthly','hourly','session') or p_base_pay<0 or p_base_pay>100000000000 or p_commission is null or p_commission not between 0 and 10000 then raise exception 'INVALID_INPUT'; end if;
 if p_id is not null and exists(select 1 from public.spa_staff where id=p_id and archived_at is not null) then raise exception 'STAFF_ARCHIVED'; end if;
 result:=public.spa_staff_save(p_id,p_name,p_name_en,p_title,p_specialty,p_bio,p_commission,p_active,p_services);
 update public.spa_staff set pay_basis=p_pay_basis,base_pay_cents=p_base_pay where id=result;
 perform spa_private.audit('staff.compensation_saved',result::text,jsonb_build_object('pay_basis',p_pay_basis,'base_pay_cents',p_base_pay,'commission_bps',p_commission));
 return result;
end $$;
create or replace function public.spa_staff_account_target(p_staff uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);
 if not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'NOT_FOUND'; end if;
 if exists(select 1 from public.spa_roles where staff_id=p_staff and role='owner') then raise exception 'OWNER_PROTECTED'; end if;
 if (select count(*) from public.spa_roles where staff_id=p_staff)>1 then raise exception 'ACCOUNT_CONFLICT'; end if;
 return jsonb_build_object('staff_id',p_staff,'archived',exists(select 1 from public.spa_staff where id=p_staff and archived_at is not null),
 'account',(select jsonb_build_object('user_id',r.user_id,'role',r.role,'active',r.active,'username',r.login_name,'email',u.email) from public.spa_roles r join auth.users u on u.id=r.user_id where r.staff_id=p_staff));
end $$;
create or replace function public.spa_staff_account_link(p_staff uuid,p_user uuid,p_role text,p_active boolean,p_reset boolean default false,p_username text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);perform pg_advisory_xact_lock(726002);
 if p_username is not null and lower(btrim(p_username)) !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'INVALID_USERNAME'; end if;
 if p_username is not null and exists(select 1 from public.spa_roles where lower(login_name)=lower(btrim(p_username)) and user_id<>p_user) then raise exception 'USERNAME_TAKEN'; end if;
 if p_role is null or p_role not in ('manager','receptionist','therapist') or p_active is null or p_user is null then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and archived_at is null) then raise exception 'STAFF_ARCHIVED'; end if;
 if p_user=auth.uid() or exists(select 1 from public.spa_roles where (user_id=p_user or staff_id=p_staff) and role='owner') then raise exception 'OWNER_PROTECTED'; end if;
 if exists(select 1 from public.spa_roles where (staff_id=p_staff and user_id<>p_user) or (user_id=p_user and staff_id is distinct from p_staff)) then raise exception 'ACCOUNT_CONFLICT'; end if;
 if exists(select 1 from public.spa_customers where auth_user_id=p_user) then raise exception 'ACCOUNT_CONFLICT'; end if;
 insert into public.spa_roles(user_id,role,staff_id,active,login_name,login_after) values(p_user,p_role,p_staff,p_active,lower(btrim(p_username)),case when p_reset then date_trunc('second',clock_timestamp())+interval '1 second' end)
 on conflict(user_id) do update set role=excluded.role,active=excluded.active,login_name=coalesce(excluded.login_name,spa_roles.login_name),login_after=case when p_reset or not p_active then date_trunc('second',clock_timestamp())+interval '1 second' else spa_roles.login_after end;
 perform spa_private.audit(case when p_reset then 'account.password_reset_requested' else 'account.access_saved' end,p_staff::text,jsonb_build_object('user_id',p_user,'role',p_role,'active',p_active,'username',p_username));
end $$;
create or replace function public.spa_staff_archive(p_staff uuid,p_archive boolean,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);perform pg_advisory_xact_lock(726001);perform pg_advisory_xact_lock(726002);
 if p_archive is null or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'NOT_FOUND'; end if;
 if exists(select 1 from public.spa_roles where staff_id=p_staff and role='owner') then raise exception 'OWNER_PROTECTED'; end if;
 if p_archive and exists(select 1 from public.spa_appointments where staff_id=p_staff and status in ('pending','confirmed','checked_in') and blocked_until>now()) then raise exception 'EXISTING_BOOKINGS'; end if;
 update public.spa_staff set active=false,archived_at=case when p_archive then coalesce(archived_at,now()) end where id=p_staff;
 update public.spa_roles set active=false,login_after=date_trunc('second',clock_timestamp())+interval '1 second' where staff_id=p_staff;
 perform spa_private.audit(case when p_archive then 'staff.archived' else 'staff.restored' end,p_staff::text,jsonb_build_object('reason',p_reason));
end $$;
-- The existing owner identities cannot be changed through personnel management.
create or replace function public.spa_role_save(p_user uuid,p_role text,p_staff uuid,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);
 if p_role='owner' or exists(select 1 from public.spa_roles where user_id=p_user and role='owner') then raise exception 'OWNER_PROTECTED'; end if;
 perform public.spa_staff_account_link(p_staff,p_user,p_role,p_active,false);
end $$;

create or replace function public.spa_staff_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid;
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select staff_id into person from public.spa_roles where user_id=auth.uid() and active;
 if person is null then return jsonb_build_object('profile',null); end if;
 return jsonb_build_object('profile',(select jsonb_build_object('id',s.id,'name',s.name,'title',s.title,'pay_basis',s.pay_basis,'base_pay_cents',s.base_pay_cents,'commission_bps',s.commission_bps,'active',s.active) from public.spa_staff s where s.id=person),
 'lifetime_completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed'),
 'metrics',jsonb_build_object('completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed' and business_date between p_from and p_to),
 'minutes',coalesce((select sum(extract(epoch from ends_at-starts_at)/60)::bigint from public.spa_appointments where staff_id=person and status='completed' and business_date between p_from and p_to),0),
 'commission_cents',coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=person and a.business_date between p_from and p_to and ch.refunded_at is null),0),
 'rating',(select round(avg(r.rating),2) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to),
 'reviews',(select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to)),
 'reviews',coalesce((select jsonb_agg(to_jsonb(x)) from (select r.rating,r.comment,r.reply,r.status,r.created_at,a.reference,a.service_name from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to order by r.created_at desc limit 100) x),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s where s.staff_id=person),'[]'),
 'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where t.staff_id=person and t.ends_at>now()-interval '7 days'),'[]'));
end $$;

create or replace function spa_private.booking_summary(a public.spa_appointments) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',a.id,'reference',a.reference,'service_id',a.service_id,'service_name',a.service_name,
 'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,'staff_id',a.staff_id,
 'therapist',(select name from public.spa_staff where id=a.staff_id),'price_cents',a.price_cents+a.tea_cents,
 'change_before',a.starts_at-make_interval(hours=>s.cancellation_hours),'can_change',a.status in ('pending','confirmed') and a.starts_at>=now()+make_interval(hours=>s.cancellation_hours),
 'can_review',a.status='completed' and not exists(select 1 from public.spa_reviews where appointment_id=a.id),
 'review_submitted',exists(select 1 from public.spa_reviews where appointment_id=a.id)) from public.spa_settings s
$$;
create or replace function public.spa_customer_review(p_access uuid,p_appointment uuid,p_rating int,p_comment text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments;
begin
 a:=spa_private.access_appointment(p_access,p_appointment);
 perform public.spa_submit_review(a.review_token,p_rating,p_comment);
 return spa_private.booking_summary(a);
end $$;
-- Existing member details gain the same review eligibility without leaking other customers' tokens.
create or replace function public.spa_customer_detail(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.spa_customers where id=p_customer and auth_user_id=auth.uid()) then perform spa_private.require_role(array['owner']); end if;
 return jsonb_build_object('wallet',coalesce((select jsonb_agg(to_jsonb(w) order by created_at desc) from public.spa_wallet_entries w where customer_id=p_customer),'[]'),
 'packages',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('remaining',p.sessions+coalesce((select sum(delta) from public.spa_package_entries where package_id=p.id),0),'service_name',s.name)) from public.spa_packages p join public.spa_services s on s.id=p.service_id where p.customer_id=p_customer),'[]'),
 'appointments',coalesce((select jsonb_agg(spa_private.booking_summary(a)||jsonb_build_object('review_token',case when a.status='completed' then a.review_token end,'manage_token',a.manage_token) order by a.starts_at desc) from public.spa_appointments a where a.customer_id=p_customer),'[]'));
end $$;

-- Username lookup is only callable by the login server; account limits commit even for unknown names.
create or replace function public.spa_staff_login_lookup(p_username text) returns jsonb language plpgsql security definer set search_path='' as $$
declare uname text:=lower(btrim(p_username)); attempts int;
begin
 if uname is null or uname !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then return null; end if;
 perform pg_advisory_xact_lock(726004);
 insert into public.spa_staff_login_limits(login_hash,window_start,attempts) values(md5(uname),now(),1)
 on conflict(login_hash) do update set window_start=case when spa_staff_login_limits.window_start<=now()-interval '10 minutes' then now() else spa_staff_login_limits.window_start end,
 attempts=case when spa_staff_login_limits.window_start<=now()-interval '10 minutes' then 1 else spa_staff_login_limits.attempts+1 end returning spa_staff_login_limits.attempts into attempts;
 delete from public.spa_staff_login_limits where window_start<now()-interval '1 day';
 if attempts>20 then return jsonb_build_object('limited',true); end if;
 return (select jsonb_build_object('email',u.email,'user_id',r.user_id) from public.spa_roles r join auth.users u on u.id=r.user_id join public.spa_staff s on s.id=r.staff_id where r.login_name=uname and r.active and r.role<>'owner' and s.archived_at is null);
end $$;
revoke all on function public.spa_staff_login_lookup(text) from public,anon,authenticated;
grant execute on function public.spa_staff_login_lookup(text) to service_role;
revoke all on function spa_private.require_team() from public,anon,authenticated;
grant execute on function spa_private.require_team() to service_role;
revoke all on function public.spa_employee_customer(uuid),public.spa_staff_profile_save(uuid,text,text,text,text,text,int,boolean,uuid[],text,bigint),public.spa_staff_account_target(uuid),public.spa_staff_account_link(uuid,uuid,text,boolean,boolean,text),public.spa_staff_archive(uuid,boolean,text),public.spa_staff_self(date,date),public.spa_customer_review(uuid,uuid,int,text) from public,anon,authenticated;
grant execute on function public.spa_employee_customer(uuid),public.spa_staff_profile_save(uuid,text,text,text,text,text,int,boolean,uuid[],text,bigint),public.spa_staff_account_target(uuid),public.spa_staff_account_link(uuid,uuid,text,boolean,boolean,text),public.spa_staff_archive(uuid,boolean,text),public.spa_staff_self(date,date),public.spa_customer_review(uuid,uuid,int,text) to authenticated,service_role;
grant execute on function public.spa_customer_review(uuid,uuid,int,text) to anon;
notify pgrst,'reload schema';
commit;
