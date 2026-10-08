begin;

-- Permission checks must use the same identity validity as the login session:
-- password resets, disabled roles and inactive personnel revoke old JWTs too.
create or replace function spa_private.role_name() returns text
language sql stable security definer set search_path='' as $$
 select r.role from public.spa_roles r
 join public.spa_role_profiles p on p.code=r.role
 where r.user_id=auth.uid() and r.active and p.active and p.archived_at is null
 and (r.role='owner' or (r.login_after is null or to_timestamp(coalesce(nullif(auth.jwt()->>'iat',''),'0')::double precision)>=r.login_after))
 and (r.role='owner' or r.staff_id is null or exists(
  select 1 from public.spa_staff s where s.id=r.staff_id and s.active and s.employment_status='active' and s.archived_at is null))
$$;

create or replace function spa_private.has_permission(p_permission text) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(spa_private.role_name()='owner' or exists(
  select 1 from public.spa_role_permissions rp
  where rp.role_code=spa_private.role_name() and rp.permission_code=p_permission
 ),false)
$$;

-- The owner-created role list used by the UI is also the server-side role list.
create or replace function public.spa_staff_account_link(p_staff uuid,p_user uuid,p_role text,p_active boolean,p_reset boolean default false,p_username text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);perform pg_advisory_xact_lock(726002);
 if p_username is not null and lower(btrim(p_username)) !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'INVALID_USERNAME'; end if;
 if p_username is not null and exists(select 1 from public.spa_roles where lower(login_name)=lower(btrim(p_username)) and user_id<>p_user) then raise exception 'USERNAME_TAKEN'; end if;
 if p_active is null or p_user is null or p_role is null or p_role='owner' or not exists(
  select 1 from public.spa_role_profiles where code=p_role and (not p_active or (active and archived_at is null))
 ) then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and archived_at is null) then raise exception 'STAFF_ARCHIVED'; end if;
 if p_active and not exists(select 1 from public.spa_staff where id=p_staff and active and employment_status='active' and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_user=auth.uid() or exists(select 1 from public.spa_roles where (user_id=p_user or staff_id=p_staff) and role='owner') then raise exception 'OWNER_PROTECTED'; end if;
 if exists(select 1 from public.spa_roles where (staff_id=p_staff and user_id<>p_user) or (user_id=p_user and staff_id is distinct from p_staff)) then raise exception 'ACCOUNT_CONFLICT'; end if;
 if exists(select 1 from public.spa_customers where auth_user_id=p_user) then raise exception 'ACCOUNT_CONFLICT'; end if;
 insert into public.spa_roles(user_id,role,staff_id,active,login_name,login_after)
 values(p_user,p_role,p_staff,p_active,lower(btrim(p_username)),case when p_reset then date_trunc('second',clock_timestamp())+interval '1 second' end)
 on conflict(user_id) do update set role=excluded.role,active=excluded.active,login_name=coalesce(excluded.login_name,spa_roles.login_name),
 login_after=case when p_reset or not p_active then date_trunc('second',clock_timestamp())+interval '1 second' else spa_roles.login_after end;
 perform spa_private.audit(case when p_reset then 'account.password_reset_requested' else 'account.access_saved' end,p_staff::text,jsonb_build_object('user_id',p_user,'role',p_role,'active',p_active,'username',p_username));
end $$;

create or replace function public.spa_staff_login_lookup(p_username text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uname text:=lower(btrim(p_username)); attempts int;
begin
 if uname is null or uname !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then return null; end if;
 perform pg_advisory_xact_lock(726004);
 insert into public.spa_staff_login_limits(login_hash,window_start,attempts) values(md5(uname),now(),1)
 on conflict(login_hash) do update set window_start=case when spa_staff_login_limits.window_start<=now()-interval '10 minutes' then now() else spa_staff_login_limits.window_start end,
 attempts=case when spa_staff_login_limits.window_start<=now()-interval '10 minutes' then 1 else spa_staff_login_limits.attempts+1 end returning spa_staff_login_limits.attempts into attempts;
 delete from public.spa_staff_login_limits where window_start<now()-interval '1 day';
 if attempts>20 then return jsonb_build_object('limited',true); end if;
 return (select jsonb_build_object('email',u.email,'user_id',r.user_id)
  from public.spa_roles r join auth.users u on u.id=r.user_id join public.spa_staff s on s.id=r.staff_id
  join public.spa_role_profiles p on p.code=r.role
  where r.login_name=uname and r.active and r.role<>'owner' and p.active and p.archived_at is null
  and s.active and s.employment_status='active' and s.archived_at is null);
end $$;

-- Archiving a customer immediately invalidates previously issued member tokens.
create or replace function spa_private.booking_access_customer(p_access uuid) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare customer uuid;
begin
 select a.customer_id into customer from public.spa_booking_access a
 join public.spa_customers c on c.id=a.customer_id
 where a.token=p_access and a.expires_at>now() and c.status='active' and c.archived_at is null;
 if customer is null then raise exception 'BOOKING_ACCESS_EXPIRED' using errcode='42501'; end if;
 return customer;
end $$;

create or replace function public.spa_member_detail(p_access uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare customer uuid;
begin
 customer:=spa_private.booking_access_customer(p_access);
 if exists(select 1 from public.spa_booking_access where token=p_access and appointment_id is not null) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 return spa_private.member_snapshot(customer);
end $$;

create or replace function public.spa_booking_link_access(p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; access uuid;
begin
 select ap.* into a from public.spa_appointments ap join public.spa_customers c on c.id=ap.customer_id
 where ap.manage_token=p_token and c.status='active' and c.archived_at is null;
 if a.id is null then return null; end if;
 insert into public.spa_booking_access(customer_id,appointment_id) values(a.customer_id,a.id) returning token into access;
 return jsonb_build_object('access_token',access,'expires_at',now()+interval '20 minutes','appointments',jsonb_build_array(spa_private.booking_summary(a)));
end $$;

-- Rewards are usable in both appointment checkout and POS. A single request
-- stores its payload/result so double clicks and network retries cannot charge
-- again or consume a different coupon. All mutations stay in one transaction.
alter table public.spa_coupons add column if not exists checkout_id uuid references public.spa_checkouts on delete set null;
create unique index if not exists spa_coupons_checkout_unique on public.spa_coupons(checkout_id) where checkout_id is not null;
create unique index if not exists spa_coupons_order_unique on public.spa_coupons(order_id) where order_id is not null;
create table if not exists public.spa_sale_requests (
 request_id uuid primary key,
 kind text not null check(kind in ('appointment','pos')),
 payload jsonb not null,
 result jsonb not null,
 checkout_id uuid unique references public.spa_checkouts on delete cascade,
 order_id uuid unique references public.spa_orders on delete cascade,
 created_at timestamptz not null default now(),
 check((checkout_id is not null)<>(order_id is not null))
);
alter table public.spa_sale_requests enable row level security;
revoke all on public.spa_sale_requests from public,anon,authenticated;
grant all on public.spa_sale_requests to service_role;

create or replace function public.spa_customer_coupons_admin(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('pos.use');
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'code',code,'title',title,'amount_cents',amount_cents,'expires_at',expires_at) order by expires_at)
  from public.spa_coupons where customer_id=p_customer and status='active' and expires_at>now()),'[]'::jsonb);
end $$;

create or replace function public.spa_checkout_with_coupon(p_request uuid,p_appointment uuid,p_discount bigint,p_wallet bigint,p_package uuid,p_tip bigint,p_method text,p_coupon uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; reward public.spa_coupons; prior public.spa_sale_requests; sale jsonb; payload jsonb;
begin
 perform spa_private.require_permission('pos.use');
 if p_request is null then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726001);perform pg_advisory_xact_lock(726005);perform pg_advisory_xact_lock(726006);perform pg_advisory_xact_lock(726099);
 payload:=jsonb_build_object('appointment',p_appointment,'discount',p_discount,'wallet',p_wallet,'package',p_package,'tip',p_tip,'method',p_method,'coupon',p_coupon);
 select * into prior from public.spa_sale_requests where request_id=p_request;
 if found then if prior.kind<>'appointment' or prior.payload<>payload then raise exception 'REQUEST_CONFLICT'; end if; return prior.result; end if;
 if exists(select 1 from public.spa_checkouts where request_id=p_request) or exists(select 1 from public.spa_orders where request_id=p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_coupon is not null then
  if p_package is not null then raise exception 'COUPON_WITH_PACKAGE'; end if;
  select * into reward from public.spa_coupons where id=p_coupon for update;
  if not found or reward.customer_id<>a.customer_id or reward.status<>'active' or reward.expires_at<=now() then raise exception 'COUPON_UNAVAILABLE'; end if;
 end if;
 sale:=public.spa_checkout(p_request,p_appointment,p_discount+coalesce(reward.amount_cents,0),p_wallet,p_package,p_tip,p_method);
 if p_coupon is not null then
  update public.spa_coupons set status='redeemed',redeemed_at=now(),checkout_id=(sale->>'id')::uuid,order_id=null where id=reward.id;
  perform spa_private.audit('coupon.redeemed',reward.id::text,jsonb_build_object('checkout',sale->>'id','amount_cents',reward.amount_cents));
 end if;
 sale:=sale||jsonb_build_object('coupon_id',p_coupon,'coupon_discount_cents',coalesce(reward.amount_cents,0));
 insert into public.spa_sale_requests(request_id,kind,payload,result,checkout_id) values(p_request,'appointment',payload,sale,(sale->>'id')::uuid);
 return sale;
end $$;

create or replace function public.spa_pos_checkout_with_coupon(p_request uuid,p_customer uuid,p_items jsonb,p_discount bigint,p_method text,p_note text default '',p_coupon uuid default null,p_expected_total bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare reward public.spa_coupons; prior public.spa_sale_requests; sale jsonb; payload jsonb;
begin
 perform spa_private.require_permission('pos.use');
 if p_request is null then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726001);perform pg_advisory_xact_lock(726005);perform pg_advisory_xact_lock(726006);perform pg_advisory_xact_lock(726099);
 payload:=jsonb_build_object('customer',p_customer,'items',p_items,'discount',p_discount,'method',p_method,'note',p_note,'coupon',p_coupon,'expected_total',p_expected_total);
 select * into prior from public.spa_sale_requests where request_id=p_request;
 if found then if prior.kind<>'pos' or prior.payload<>payload then raise exception 'REQUEST_CONFLICT'; end if; return prior.result; end if;
 if exists(select 1 from public.spa_orders where request_id=p_request) or exists(select 1 from public.spa_checkouts where request_id=p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 if p_coupon is not null then
  select * into reward from public.spa_coupons where id=p_coupon for update;
  if not found or p_customer is null or reward.customer_id<>p_customer or reward.status<>'active' or reward.expires_at<=now() then raise exception 'COUPON_UNAVAILABLE'; end if;
 end if;
 sale:=public.spa_pos_checkout(p_request,p_customer,p_items,p_discount+coalesce(reward.amount_cents,0),p_method,p_note);
 if p_expected_total is not null and (sale->>'total_cents')::bigint<>p_expected_total then raise exception 'PRICE_CHANGED'; end if;
 if p_coupon is not null then
  update public.spa_coupons set status='redeemed',redeemed_at=now(),order_id=(sale->>'id')::uuid,checkout_id=null where id=reward.id;
  perform spa_private.audit('coupon.redeemed',reward.id::text,jsonb_build_object('order',sale->>'id','amount_cents',reward.amount_cents));
 end if;
 sale:=sale||jsonb_build_object('coupon_id',p_coupon,'coupon_discount_cents',coalesce(reward.amount_cents,0));
 insert into public.spa_sale_requests(request_id,kind,payload,result,order_id) values(p_request,'pos',payload,sale,(sale->>'id')::uuid);
 return sale;
end $$;

create or replace function spa_private.release_sale_coupon() returns trigger
language plpgsql security definer set search_path='' as $$
declare should_release boolean;
begin
 should_release:=tg_op='DELETE';
 if tg_op='UPDATE' then
  if tg_table_name='spa_checkouts' then should_release:=old.refunded_at is null and new.refunded_at is not null;
  else should_release:=old.status='paid' and new.status in ('refunded','void'); end if;
 end if;
 if should_release then
  if tg_table_name='spa_checkouts' then
   update public.spa_coupons set status='active',redeemed_at=null,checkout_id=null,order_id=null where checkout_id=old.id and status='redeemed';
  else
   update public.spa_coupons set status='active',redeemed_at=null,checkout_id=null,order_id=null where order_id=old.id and status='redeemed';
  end if;
  perform spa_private.audit('coupon.sale_released',old.id::text,jsonb_build_object('sale_type',tg_table_name,'operation',tg_op));
 end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
drop trigger if exists spa_checkout_coupon_release on public.spa_checkouts;
create trigger spa_checkout_coupon_release before update or delete on public.spa_checkouts for each row execute function spa_private.release_sale_coupon();
drop trigger if exists spa_order_coupon_release on public.spa_orders;
create trigger spa_order_coupon_release before update or delete on public.spa_orders for each row execute function spa_private.release_sale_coupon();

revoke all on function spa_private.release_sale_coupon() from public,anon,authenticated;
grant execute on function spa_private.release_sale_coupon() to service_role;
revoke all on function public.spa_customer_coupons_admin(uuid),public.spa_checkout_with_coupon(uuid,uuid,bigint,bigint,uuid,bigint,text,uuid),public.spa_pos_checkout_with_coupon(uuid,uuid,jsonb,bigint,text,text,uuid,bigint) from public,anon,authenticated;
grant execute on function public.spa_customer_coupons_admin(uuid),public.spa_checkout_with_coupon(uuid,uuid,bigint,bigint,uuid,bigint,text,uuid),public.spa_pos_checkout_with_coupon(uuid,uuid,jsonb,bigint,text,text,uuid,bigint) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
