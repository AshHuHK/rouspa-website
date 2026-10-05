begin;

-- Reviews earn one traceable NT$50 coupon for the customer who completed the
-- appointment. The appointment unique key makes the reward idempotent even if
-- the browser retries a submission.
create table if not exists public.spa_coupons (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.spa_customers on delete cascade,
 appointment_id uuid not null unique references public.spa_appointments on delete cascade,
 code text not null unique,
 title text not null default '療程評價回饋券',
 amount_cents bigint not null default 5000 check(amount_cents>0),
 status text not null default 'active' check(status in ('active','redeemed','void')),
 issued_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '90 days',
 redeemed_at timestamptz,
 order_id uuid references public.spa_orders on delete set null,
 check(expires_at>issued_at),
 check((status='redeemed')=(redeemed_at is not null))
);
create index if not exists spa_coupons_customer on public.spa_coupons(customer_id,issued_at desc);
alter table public.spa_coupons enable row level security;
revoke all on public.spa_coupons from public,anon,authenticated;
grant all on public.spa_coupons to service_role;

-- A first appointment turns the automatically-created customer record into a
-- member profile. Existing names and contact data are deliberately preserved.
create or replace function spa_private.promote_booking_customer() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update public.spa_customers set customer_type='member',status='active',archived_at=null where id=new.customer_id;
 return new;
end $$;
drop trigger if exists spa_appointment_promote_customer on public.spa_appointments;
create trigger spa_appointment_promote_customer after insert on public.spa_appointments
for each row execute function spa_private.promote_booking_customer();
update public.spa_customers c set customer_type='member'
where exists(select 1 from public.spa_appointments a where a.customer_id=c.id);

create or replace function public.spa_submit_review(p_token uuid,p_rating int,p_comment text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; inserted_count int;
begin
 select * into a from public.spa_appointments where review_token=p_token and status='completed' for update;
 if not found then raise exception 'REVIEW_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>1000 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_reviews(appointment_id,rating,comment) values(a.id,p_rating,btrim(p_comment))
 on conflict(appointment_id) do nothing;
 get diagnostics inserted_count=row_count;
 if inserted_count=1 then
  insert into public.spa_coupons(customer_id,appointment_id,code)
  values(a.customer_id,a.id,'ROU50-'||upper(substr(replace(a.id::text,'-',''),1,12)))
  on conflict(appointment_id) do nothing;
 end if;
end $$;

create or replace function public.spa_review_context(p_token uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('reference',a.reference,'service_name',a.service_name,'therapist',s.name,
  'submitted',exists(select 1 from public.spa_reviews where appointment_id=a.id),
  'reward_cents',5000,
  'coupon',(select jsonb_build_object('code',c.code,'amount_cents',c.amount_cents,'expires_at',c.expires_at) from public.spa_coupons c where c.appointment_id=a.id))
 from public.spa_appointments a join public.spa_staff s on s.id=a.staff_id
 where a.review_token=p_token and a.status='completed'
$$;

create or replace function public.spa_customer_review(p_access uuid,p_appointment uuid,p_rating int,p_comment text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; reward jsonb;
begin
 a:=spa_private.access_appointment(p_access,p_appointment);
 perform public.spa_submit_review(a.review_token,p_rating,p_comment);
 select jsonb_build_object('code',c.code,'amount_cents',c.amount_cents,'expires_at',c.expires_at) into reward
 from public.spa_coupons c where c.appointment_id=a.id;
 return spa_private.booking_summary(a)||jsonb_build_object('coupon',reward);
end $$;

create or replace function spa_private.member_snapshot(p_customer uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'profile',(select jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'tier',c.tier,'customer_type',c.customer_type,'created_at',c.created_at) from public.spa_customers c where c.id=p_customer),
  'wallet_balance_cents',coalesce((select sum(w.amount_cents) from public.spa_wallet_entries w where w.customer_id=p_customer),0),
  'wallet',coalesce((select jsonb_agg(jsonb_build_object('id',w.id,'amount_cents',w.amount_cents,'kind',w.kind,'note',w.note,'created_at',w.created_at) order by w.created_at desc) from public.spa_wallet_entries w where w.customer_id=p_customer),'[]'::jsonb),
  'packages',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('remaining',p.sessions+coalesce((select sum(e.delta) from public.spa_package_entries e where e.package_id=p.id),0),'service_name',s.name) order by p.created_at desc) from public.spa_packages p join public.spa_services s on s.id=p.service_id where p.customer_id=p_customer),'[]'::jsonb),
  'appointments',coalesce((select jsonb_agg(spa_private.booking_summary(a) order by a.starts_at desc) from public.spa_appointments a where a.customer_id=p_customer),'[]'::jsonb),
  'coupons',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'title',c.title,'amount_cents',c.amount_cents,'status',case when c.status='active' and c.expires_at<=now() then 'expired' else c.status end,'issued_at',c.issued_at,'expires_at',c.expires_at,'redeemed_at',c.redeemed_at,'appointment_id',c.appointment_id) order by c.issued_at desc) from public.spa_coupons c where c.customer_id=p_customer),'[]'::jsonb),
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'reference',o.reference,'status',o.status,'subtotal_cents',o.subtotal_cents,'discount_cents',o.discount_cents,'total_cents',o.total_cents,'method',o.method,'note',o.note,'paid_at',o.paid_at,'created_at',o.created_at,'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'item_type',i.item_type,'name',i.name_snapshot,'quantity',i.quantity,'unit_price_cents',i.unit_price_cents,'line_total_cents',i.line_total_cents) order by i.id) from public.spa_order_items i where i.order_id=o.id),'[]'::jsonb)) order by coalesce(o.paid_at,o.created_at) desc) from public.spa_orders o where o.customer_id=p_customer),'[]'::jsonb)
 )
$$;

create or replace function public.spa_member_detail(p_access uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare customer uuid;
begin
 customer:=spa_private.booking_access_customer(p_access);
 return spa_private.member_snapshot(customer);
end $$;

-- Name + phone is the requested member sign-in method. Exact matching,
-- rate-limiting and a two-hour in-memory access token limit exposure.
create or replace function public.spa_member_login(p_phone text,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare tel text; customer uuid; access uuid; attempt int; key_hash text; expiry timestamptz:=now()+interval '2 hours';
begin
 tel:=spa_private.phone(p_phone);
 if tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726003);
 key_hash:=md5('member:'||tel);
 insert into public.spa_booking_lookup_limits(phone_hash,window_start,attempts) values(key_hash,now(),1)
 on conflict(phone_hash) do update set
  window_start=case when spa_booking_lookup_limits.window_start<=now()-interval '10 minutes' then now() else spa_booking_lookup_limits.window_start end,
  attempts=case when spa_booking_lookup_limits.window_start<=now()-interval '10 minutes' then 1 else spa_booking_lookup_limits.attempts+1 end
 returning attempts into attempt;
 if attempt>10 then raise exception 'RATE_LIMIT'; end if;
 select c.id into customer from public.spa_customers c
 where c.phone=tel and lower(btrim(c.name))=lower(btrim(p_name)) and c.customer_type='member' and c.status='active' and c.archived_at is null;
 if customer is null then return jsonb_build_object('member',null); end if;
 delete from public.spa_booking_access where expires_at<=now();
 delete from public.spa_booking_lookup_limits where window_start<now()-interval '1 day';
 insert into public.spa_booking_access(customer_id,expires_at) values(customer,expiry) returning token into access;
 return jsonb_build_object('access_token',access,'expires_at',expiry,'member',spa_private.member_snapshot(customer));
end $$;

-- Weekly and dated rosters share one validation model. An existing live booking
-- can never be placed outside the new hours by a bulk calendar edit.
create or replace function public.spa_weekly_shift_save(p_staff uuid,p_weekday int,p_is_working boolean,p_start int,p_end int)
returns void language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001);
 if p_weekday not between 0 and 6 or p_is_working is null or p_start<0 or p_end<=p_start or p_end>2880 then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and active and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 select * into cfg from public.spa_settings;
 if exists(
  select 1 from public.spa_appointments a
  left join public.spa_daily_shifts d on d.staff_id=a.staff_id and d.business_date=a.business_date
  where a.staff_id=p_staff and a.business_date>=(now() at time zone cfg.timezone)::date
   and extract(dow from a.business_date)::int=p_weekday and d.id is null
   and a.status in ('pending','confirmed','checked_in','in_service')
   and (not p_is_working
    or a.starts_at<((a.business_date::timestamp+make_interval(mins=>p_start)) at time zone cfg.timezone)
    or a.blocked_until>((a.business_date::timestamp+make_interval(mins=>p_end)) at time zone cfg.timezone))
 ) then raise exception 'EXISTING_BOOKINGS'; end if;
 if p_is_working then
  insert into public.spa_shifts(staff_id,weekday,start_minute,end_minute) values(p_staff,p_weekday,p_start,p_end)
  on conflict(staff_id,weekday) do update set start_minute=excluded.start_minute,end_minute=excluded.end_minute;
 else delete from public.spa_shifts where staff_id=p_staff and weekday=p_weekday;
 end if;
 perform spa_private.audit('weekly_shift.saved',p_staff::text,jsonb_build_object('weekday',p_weekday,'working',p_is_working,'start',p_start,'end',p_end));
end $$;

create or replace function public.spa_daily_shift_bulk_save(p_staff uuid,p_dates date[],p_is_working boolean,p_start int,p_end int,p_note text default '')
returns void language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; work_date date;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001);
 if coalesce(cardinality(p_dates),0) not between 1 and 62 or p_is_working is null or p_start<0 or p_end<=p_start or p_end>2880 or length(coalesce(p_note,''))>500 then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and active and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 select * into cfg from public.spa_settings;
 if exists(select 1 from unnest(p_dates) d where d is null or d<(now() at time zone cfg.timezone)::date or d>(now() at time zone cfg.timezone)::date+366) then raise exception 'INVALID_DATE'; end if;
 for work_date in select distinct d from unnest(p_dates) d loop
  if exists(select 1 from public.spa_appointments a where a.staff_id=p_staff and a.business_date=work_date and a.status in ('pending','confirmed','checked_in','in_service')
   and (not p_is_working
    or a.starts_at<((work_date::timestamp+make_interval(mins=>p_start)) at time zone cfg.timezone)
    or a.blocked_until>((work_date::timestamp+make_interval(mins=>p_end)) at time zone cfg.timezone))) then raise exception 'EXISTING_BOOKINGS'; end if;
 end loop;
 insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
 select p_staff,d,p_is_working,p_start,p_end,btrim(coalesce(p_note,'')),auth.uid(),now() from (select distinct unnest(p_dates) d) dates
 on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 perform spa_private.audit('daily_shift.bulk_saved',p_staff::text,jsonb_build_object('dates',p_dates,'working',p_is_working,'start',p_start,'end',p_end,'note',p_note));
end $$;

create or replace function public.spa_daily_shift_bulk_delete(p_staff uuid,p_dates date[])
returns void language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001);
 if coalesce(cardinality(p_dates),0) not between 1 and 62 then raise exception 'INVALID_INPUT'; end if;
 select * into cfg from public.spa_settings;
 if exists(
  select 1 from public.spa_appointments a
  left join public.spa_shifts w on w.staff_id=a.staff_id and w.weekday=extract(dow from a.business_date)::int
  where a.staff_id=p_staff and a.business_date=any(p_dates) and a.status in ('pending','confirmed','checked_in','in_service')
   and (w.id is null
    or a.starts_at<((a.business_date::timestamp+make_interval(mins=>w.start_minute)) at time zone cfg.timezone)
    or a.blocked_until>((a.business_date::timestamp+make_interval(mins=>w.end_minute)) at time zone cfg.timezone))
 ) then raise exception 'EXISTING_BOOKINGS'; end if;
 delete from public.spa_daily_shifts where staff_id=p_staff and business_date=any(p_dates);
 perform spa_private.audit('daily_shift.bulk_deleted',p_staff::text,jsonb_build_object('dates',p_dates));
end $$;

revoke all on function spa_private.promote_booking_customer(),spa_private.member_snapshot(uuid) from public,anon,authenticated;
grant execute on function spa_private.promote_booking_customer(),spa_private.member_snapshot(uuid) to service_role;
revoke all on function public.spa_member_login(text,text),public.spa_member_detail(uuid),public.spa_weekly_shift_save(uuid,int,boolean,int,int),public.spa_daily_shift_bulk_save(uuid,date[],boolean,int,int,text),public.spa_daily_shift_bulk_delete(uuid,date[]) from public,anon,authenticated;
grant execute on function public.spa_member_login(text,text),public.spa_member_detail(uuid) to anon,authenticated,service_role;
grant execute on function public.spa_weekly_shift_save(uuid,int,boolean,int,int),public.spa_daily_shift_bulk_save(uuid,date[],boolean,int,int,text),public.spa_daily_shift_bulk_delete(uuid,date[]) to authenticated,service_role;
grant execute on function public.spa_submit_review(uuid,int,text),public.spa_review_context(uuid),public.spa_customer_review(uuid,uuid,int,text) to anon,authenticated,service_role;

notify pgrst,'reload schema';
commit;
