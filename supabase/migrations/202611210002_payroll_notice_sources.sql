begin;

create table spa_private.payroll_notice_minutes (
 source_kind text not null check(source_kind in ('appointment','pos_service')),
 source_id uuid not null,
 minutes int not null check(minutes between 1 and 144000),
 updated_by uuid references auth.users,
 updated_at timestamptz not null default now(),
 primary key(source_kind,source_id)
);

alter table public.spa_packages add column payroll_seller_id uuid references public.spa_staff;
alter table public.spa_packages add column payroll_sale_bonus_cents bigint not null default 0
 check(payroll_sale_bonus_cents between 0 and paid_cents);
create index spa_package_payroll_seller on public.spa_packages(payroll_seller_id,created_at) where payroll_sale_bonus_cents>0;
create index spa_checkouts_payroll_package on public.spa_checkouts(package_id,created_at,id) where package_id is not null and refunded_at is null;

create table spa_private.payroll_notice_returns (
 request_id uuid primary key,
 source_kind text not null check(source_kind in ('package','product')),
 source_id uuid not null,
 staff_id uuid not null references public.spa_staff,
 returned_on date not null,
 payroll_date date not null,
 amount_cents bigint not null check(amount_cents>0),
 clawback_cents bigint not null check(clawback_cents>=0),
 receipt text not null check(length(receipt) between 1 and 200),
 created_by uuid references auth.users,
 created_at timestamptz not null default now(),
 unique(source_kind,source_id,receipt)
);
create index payroll_notice_returns_staff on spa_private.payroll_notice_returns(staff_id,payroll_date);
alter table spa_private.payroll_notice_minutes enable row level security;
alter table spa_private.payroll_notice_returns enable row level security;
revoke all on spa_private.payroll_notice_minutes,spa_private.payroll_notice_returns from public,anon,authenticated;

create function spa_private.payroll_notice_rule_on(p_day date) returns uuid
language sql stable security definer set search_path='' as $$
 select id from public.spa_payroll_rule_versions where status='active' and effective_from<=p_day
 order by effective_from desc,version_no desc limit 1;
$$;

create function spa_private.payroll_notice_mark_input(p_day date) returns void
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.spa_payroll_runs where status='finalized' and p_day between period_start and period_end)
 then raise exception 'PAYROLL_LOCKED'; end if;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and p_day between period_start and period_end;
end $$;

create function public.spa_payroll_notice_minutes_save(p_kind text,p_source uuid,p_minutes int) returns void
language plpgsql security definer set search_path='' as $$
declare day date; quantity int;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726005);
 if p_kind='appointment' then
  select a.business_date,1 into day,quantity from public.spa_appointments a
  join public.spa_checkouts c on c.appointment_id=a.id and c.refunded_at is null
  where a.id=p_source and a.status='completed';
 elsif p_kind='pos_service' then
  select (o.paid_at at time zone 'Asia/Taipei')::date,i.quantity into day,quantity
  from public.spa_order_items i join public.spa_orders o on i.order_id=o.id
  where i.id=p_source and i.item_type='service' and o.status='paid';
 end if;
 if day is null then raise exception 'NOT_FOUND'; end if;
 if p_minutes is not null and p_minutes not between quantity and least(144000,quantity*1440)
 then raise exception 'INVALID_INPUT'; end if;
 perform spa_private.payroll_notice_mark_input(day);
 if p_minutes is null then
  delete from spa_private.payroll_notice_minutes where source_kind=p_kind and source_id=p_source;
 else
  insert into spa_private.payroll_notice_minutes(source_kind,source_id,minutes,updated_by)
  values(p_kind,p_source,p_minutes,auth.uid())
  on conflict(source_kind,source_id) do update set minutes=excluded.minutes,updated_by=excluded.updated_by,updated_at=now();
 end if;
 perform spa_private.audit('payroll.notice_minutes',p_source::text,jsonb_build_object('source',p_kind,'minutes',p_minutes));
end $$;

-- The sale and payroll snapshot share one transaction and one request ID.
alter function public.spa_package_sell(uuid,uuid,uuid,text,int,bigint,timestamptz,text) set schema spa_private;
alter function spa_private.spa_package_sell(uuid,uuid,uuid,text,int,bigint,timestamptz,text) rename to package_sell_before_notice;
revoke all on function spa_private.package_sell_before_notice(uuid,uuid,uuid,text,int,bigint,timestamptz,text) from public,anon,authenticated;

create function public.spa_package_sell_v2(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text,p_seller uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare pkg public.spa_packages; day date:=(now() at time zone 'Asia/Taipei')::date; rule uuid; bonus bigint:=0;
begin
 perform spa_private.require_permission('customers.manage');
 perform pg_advisory_xact_lock(726001);
 perform pg_advisory_xact_lock(726005);
 select * into pkg from public.spa_packages where request_id=p_request;
 if pkg.id is not null then
  if pkg.payroll_seller_id is distinct from p_seller then raise exception 'REQUEST_CONFLICT'; end if;
 else
  rule:=spa_private.payroll_notice_rule_on(day);
  if exists(select 1 from spa_private.payroll_notices where rule_id=rule) then
   if p_seller is null then raise exception 'PAYROLL_PACKAGE_SELLER_REQUIRED'; end if;
   if exists(select 1 from spa_private.payroll_notice_staff where rule_id=rule and staff_id=p_seller) then
    bonus:=round(p_cents*0.05)::bigint;
   elsif exists(select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=p_seller and j.work_category='technician') then
    raise exception 'PAYROLL_CLASSIFICATION_REQUIRED';
   end if;
   perform spa_private.payroll_notice_mark_input(day);
  end if;
  if p_seller is not null and not exists(select 1 from public.spa_staff where id=p_seller and active and employment_status='active' and archived_at is null)
  then raise exception 'INVALID_INPUT'; end if;
 end if;
 perform spa_private.package_sell_before_notice(p_request,p_customer,p_service,p_name,p_sessions,p_cents,p_expires,p_method);
 if pkg.id is null and p_seller is not null then
  update public.spa_packages set payroll_seller_id=p_seller,payroll_sale_bonus_cents=bonus where request_id=p_request;
  perform spa_private.audit('payroll.package_sale_attributed',p_request::text,jsonb_build_object('staff_id',p_seller,'commission_cents',bonus));
 end if;
end $$;

create function public.spa_package_sell(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text) returns void
language sql security definer set search_path='' as $$
 select public.spa_package_sell_v2(p_request,p_customer,p_service,p_name,p_sessions,p_cents,p_expires,p_method,null);
$$;

create function public.spa_package_sellers() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.manage');
 return jsonb_build_object(
  'required',exists(select 1 from spa_private.payroll_notices where rule_id=spa_private.payroll_notice_rule_on((now() at time zone 'Asia/Taipei')::date)),
  'staff',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by display_order,name)
   from public.spa_staff where active and employment_status='active' and archived_at is null),'[]'));
end $$;

-- A payroll adjustment references a completed refund. It records no payment
-- and doesn't rewrite the sale, inventory or customer entitlements.
create function public.spa_payroll_notice_return(p_request uuid,p_kind text,p_source uuid,p_returned_on date,p_amount bigint,p_receipt text) returns void
language plpgsql security definer set search_path='' as $$
declare prior spa_private.payroll_notice_returns; gross bigint; sale_bonus bigint; used_amount bigint; seller uuid;
 sale_day date; payroll_day date; receipt text:=btrim(coalesce(p_receipt,''));
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726005);
 if p_request is null or p_source is null or p_returned_on is null or p_returned_on>(now() at time zone 'Asia/Taipei')::date
  or p_amount is null or p_amount<=0 or length(receipt) not between 1 and 200 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from spa_private.payroll_notice_returns where request_id=p_request;
 if found then
  if p_kind is distinct from prior.source_kind or p_source is distinct from prior.source_id or p_returned_on is distinct from prior.returned_on
    or p_amount is distinct from prior.amount_cents or receipt is distinct from prior.receipt then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 if p_kind='package' then
  select paid_cents,payroll_sale_bonus_cents,payroll_seller_id,(created_at at time zone 'Asia/Taipei')::date
  into gross,sale_bonus,seller,sale_day from public.spa_packages where id=p_source;
  payroll_day:=(date_trunc('month',p_returned_on::timestamp)+interval '1 month')::date;
 elsif p_kind='product' then
  select i.net_total_cents,round(i.net_total_cents*0.05)::bigint,i.staff_id,(o.paid_at at time zone 'Asia/Taipei')::date
  into gross,sale_bonus,seller,sale_day
  from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
  join spa_private.payroll_notice_staff s on s.rule_id=spa_private.payroll_notice_rule_on((o.paid_at at time zone 'Asia/Taipei')::date)
    and s.staff_id=i.staff_id
  where i.id=p_source and i.item_type='product' and o.status='paid';
  payroll_day:=p_returned_on;
 end if;
 if seller is null or coalesce(sale_bonus,0)<=0 or p_returned_on<sale_day then raise exception 'NOT_FOUND'; end if;
 select coalesce(sum(amount_cents),0) into used_amount from spa_private.payroll_notice_returns where source_kind=p_kind and source_id=p_source;
 if used_amount+p_amount>gross then raise exception 'INVALID_INPUT'; end if;
 perform spa_private.payroll_notice_mark_input(payroll_day);
 insert into spa_private.payroll_notice_returns(request_id,source_kind,source_id,staff_id,returned_on,payroll_date,amount_cents,clawback_cents,receipt,created_by)
 values(p_request,p_kind,p_source,seller,p_returned_on,payroll_day,p_amount,
  round(sale_bonus*(used_amount+p_amount)::numeric/gross)-round(sale_bonus*used_amount::numeric/gross),receipt,auth.uid());
 perform spa_private.audit('payroll.notice_return',p_source::text,jsonb_build_object('request_id',p_request,'date',payroll_day,'kind',p_kind));
end $$;

create function spa_private.payroll_notice_sales(p_staff uuid,p_from date,p_to date) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x) order by x.date,x.id),'[]')
 from (
  select p.id,'package_sale'::text kind,(p.created_at at time zone 'Asia/Taipei')::date date,
   p.name,p.paid_cents amount_cents,p.payroll_sale_bonus_cents commission_cents,p.request_id::text reference,p.sessions quantity
  from public.spa_packages p where p.payroll_seller_id=p_staff and p.payroll_sale_bonus_cents>0
   and (p.created_at at time zone 'Asia/Taipei')::date between p_from and p_to
  union all
  select r.request_id,r.source_kind||'_return',r.payroll_date,'退回抽成',-r.amount_cents,-r.clawback_cents,r.receipt,1
  from spa_private.payroll_notice_returns r
  where r.staff_id=p_staff and r.payroll_date between p_from and p_to
   and (r.source_kind='package' or exists(select 1 from public.spa_order_items i where i.id=r.source_id))
 )x;
$$;

revoke all on function spa_private.payroll_notice_rule_on(date),spa_private.payroll_notice_mark_input(date),spa_private.payroll_notice_sales(uuid,date,date),public.spa_payroll_notice_minutes_save(text,uuid,int),public.spa_payroll_notice_return(uuid,text,uuid,date,bigint,text),public.spa_package_sell_v2(uuid,uuid,uuid,text,int,bigint,timestamptz,text,uuid),public.spa_package_sell(uuid,uuid,uuid,text,int,bigint,timestamptz,text) from public,anon,authenticated;
grant execute on function public.spa_payroll_notice_minutes_save(text,uuid,int),public.spa_payroll_notice_return(uuid,text,uuid,date,bigint,text),public.spa_package_sell_v2(uuid,uuid,uuid,text,int,bigint,timestamptz,text,uuid),public.spa_package_sell(uuid,uuid,uuid,text,int,bigint,timestamptz,text) to authenticated,service_role;
revoke all on function public.spa_package_sellers() from public,anon,authenticated;
grant execute on function public.spa_package_sellers() to authenticated,service_role;
notify pgrst,'reload schema';
commit;
