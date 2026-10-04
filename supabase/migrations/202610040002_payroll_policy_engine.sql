begin;

-- The salary policy is configured by job title and employment type.  Keep the
-- previous fixed designated-client amount for old snapshots, but calculate all
-- new payroll with a percentage of the designated service revenue.
alter table public.spa_compensation_profiles
 add column if not exists designated_client_bonus_bps int not null default 0,
 add column if not exists minimum_attendance_minutes int not null default 0,
 add column if not exists commission_start_service_minutes int not null default 0;

alter table public.spa_compensation_profiles drop constraint if exists spa_compensation_profiles_designated_client_bonus_bps_check;
alter table public.spa_compensation_profiles add constraint spa_compensation_profiles_designated_client_bonus_bps_check check(designated_client_bonus_bps between 0 and 10000);
alter table public.spa_compensation_profiles drop constraint if exists spa_compensation_profiles_minimum_attendance_minutes_check;
alter table public.spa_compensation_profiles add constraint spa_compensation_profiles_minimum_attendance_minutes_check check(minimum_attendance_minutes between 0 and 100000);
alter table public.spa_compensation_profiles drop constraint if exists spa_compensation_profiles_commission_start_service_minutes_check;
alter table public.spa_compensation_profiles add constraint spa_compensation_profiles_commission_start_service_minutes_check check(commission_start_service_minutes between 0 and 100000);

-- Document defaults.  They remain editable in the owner payroll screen.
update public.spa_compensation_profiles
set designated_client_bonus_bps=case when designated_client_bonus_bps=0 then 500 else designated_client_bonus_bps end,
    minimum_attendance_minutes=case when employment_type_code='part_time' then 2400 else minimum_attendance_minutes end,
    commission_start_service_minutes=case when employment_type_code='full_time' then 3900 when employment_type_code='part_time' then 2400 else commission_start_service_minutes end,
    base_pay_cents=case
      when employment_type_code='full_time' and base_pay_cents=0 then 3000000
      when employment_type_code='part_time' and base_pay_cents=0 then 22000
      else base_pay_cents end,
    pay_basis=case when employment_type_code='part_time' then 'hourly' else pay_basis end;

-- Every commission tier is tied to a title and employment type. Existing
-- store-wide tiers are preserved: the original row is assigned to the first
-- current profile and copies are created for the remaining profiles.
alter table public.spa_payroll_commission_tiers
 add column if not exists job_title_id uuid references public.spa_job_titles,
 add column if not exists employment_type_code text references public.spa_employment_types(code),
 add column if not exists calculation_mode text not null default 'progressive';

alter table public.spa_payroll_commission_tiers drop constraint if exists spa_payroll_commission_tiers_calculation_mode_check;
alter table public.spa_payroll_commission_tiers add constraint spa_payroll_commission_tiers_calculation_mode_check check(calculation_mode in ('progressive','flat'));

do $$
begin
 if exists(select 1 from public.spa_payroll_commission_tiers where job_title_id is null or employment_type_code is null)
  and not exists(select 1 from public.spa_compensation_profiles) then
  raise exception 'PAYROLL_PROFILE_REQUIRED_FOR_TIER_MIGRATION';
 end if;
end $$;

with profiles as (
 select c.job_title_id,c.employment_type_code,
        row_number() over(order by c.job_title_id,c.employment_type_code) profile_no
 from public.spa_compensation_profiles c
)
insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode)
select t.rule_version_id,t.metric,t.threshold_from,t.threshold_to,t.rate_bps,t.service_category_id,p.job_title_id,p.employment_type_code,'flat'
from public.spa_payroll_commission_tiers t
cross join profiles p
where (t.job_title_id is null or t.employment_type_code is null) and p.profile_no>1;

with first_profile as (
 select c.job_title_id,c.employment_type_code
 from public.spa_compensation_profiles c
 order by c.job_title_id,c.employment_type_code
 limit 1
)
update public.spa_payroll_commission_tiers t
set job_title_id=p.job_title_id,employment_type_code=p.employment_type_code,calculation_mode='flat'
from first_profile p
where t.job_title_id is null or t.employment_type_code is null;
alter table public.spa_payroll_commission_tiers alter column job_title_id set not null;
alter table public.spa_payroll_commission_tiers alter column employment_type_code set not null;
create index if not exists spa_payroll_tiers_scope_idx on public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from);

-- Seed the detailed policy only where a profile has no existing service tier.
-- Full-time: first 65 service hours are covered by salary, then 10-hour bands.
with active_rule as (
 select id from public.spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1
), profiles as (
 select c.*,coalesce(nullif(c.service_commission_bps,0),case j.code when 'owner' then 3500 when 'manager' then 3500 when 'head_therapist' then 3000 when 'senior_therapist' then 2000 else 500 end) start_rate
 from public.spa_compensation_profiles c join public.spa_job_titles j on j.id=c.job_title_id
 where c.employment_type_code='full_time'
), bands(threshold_from,threshold_to,step_no) as (
 values (3900::bigint,4500::bigint,0),(4500,5100,1),(5100,5700,2),(5700,6300,3),(6300,6900,4),(6900,7500,5),(7500,8100,6),(8100,null,7)
)
insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode)
select r.id,p.job_title_id,p.employment_type_code,'service_minutes',b.threshold_from,b.threshold_to,least(3500,p.start_rate+b.step_no*500),'progressive'
from active_rule r cross join profiles p cross join bands b
where not exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=r.id and t.job_title_id=p.job_title_id and t.employment_type_code=p.employment_type_code and t.metric in ('service_minutes','service_count','service_sales_cents'));

-- Part-time: attendance must reach 40 hours; service bands start at hour 41.
with active_rule as (
 select id from public.spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1
), bands(threshold_from,threshold_to,rate_bps) as (
 values (2400::bigint,3000::bigint,500),(3000,3600,1000),(3600,4200,1500),(4200,4800,2000),(4800,5400,2500),(5400,null,3000)
)
insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode)
select r.id,c.job_title_id,c.employment_type_code,'service_minutes',b.threshold_from,b.threshold_to,b.rate_bps,'progressive'
from active_rule r cross join public.spa_compensation_profiles c cross join bands b
where c.employment_type_code='part_time'
and not exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=r.id and t.job_title_id=c.job_title_id and t.employment_type_code=c.employment_type_code and t.metric in ('service_minutes','service_count','service_sales_cents'));

-- Contractor default: first 100 completed services at 30%, the remainder 40%.
with active_rule as (
 select id from public.spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1
), bands(threshold_from,threshold_to,rate_bps) as (
 values (0::bigint,100::bigint,3000),(100,null,4000)
)
insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode)
select r.id,c.job_title_id,c.employment_type_code,'service_count',b.threshold_from,b.threshold_to,b.rate_bps,'progressive'
from active_rule r cross join public.spa_compensation_profiles c cross join bands b
where c.employment_type_code='contractor'
and not exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=r.id and t.job_title_id=c.job_title_id and t.employment_type_code=c.employment_type_code and t.metric in ('service_minutes','service_count','service_sales_cents'));

create or replace function public.spa_compensation_profile_save_v2(
 p_job_title uuid,p_employment_type text,p_pay_basis text,p_base_pay bigint,
 p_service_commission int,p_product_commission int,p_designated_bonus_bps int,
 p_minimum_attendance_minutes int,p_commission_start_service_minutes int,p_active boolean default true
) returns void language plpgsql security definer set search_path='' as $$
declare old jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_job_titles where id=p_job_title)
  or not exists(select 1 from public.spa_employment_types where code=p_employment_type)
  or p_pay_basis not in ('monthly','hourly','session') or p_base_pay<0
  or p_service_commission not between 0 and 10000 or p_product_commission not between 0 and 10000
  or p_designated_bonus_bps not between 0 and 10000
  or p_minimum_attendance_minutes not between 0 and 100000
  or p_commission_start_service_minutes not between 0 and 100000 or p_active is null then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(c) into old from public.spa_compensation_profiles c where c.job_title_id=p_job_title and c.employment_type_code=p_employment_type;
 insert into public.spa_compensation_profiles(job_title_id,employment_type_code,pay_basis,base_pay_cents,service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,commission_start_service_minutes,active,updated_by,updated_at)
 values(p_job_title,p_employment_type,p_pay_basis,p_base_pay,p_service_commission,p_product_commission,p_designated_bonus_bps,p_minimum_attendance_minutes,p_commission_start_service_minutes,p_active,auth.uid(),now())
 on conflict(job_title_id,employment_type_code) do update set pay_basis=excluded.pay_basis,base_pay_cents=excluded.base_pay_cents,
  service_commission_bps=excluded.service_commission_bps,product_commission_bps=excluded.product_commission_bps,
  designated_client_bonus_bps=excluded.designated_client_bonus_bps,minimum_attendance_minutes=excluded.minimum_attendance_minutes,
  commission_start_service_minutes=excluded.commission_start_service_minutes,active=excluded.active,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 update public.spa_staff set pay_basis=p_pay_basis,base_pay_cents=p_base_pay,commission_bps=p_service_commission
 where job_title_id=p_job_title and employment_type_code=p_employment_type;
 perform spa_private.audit('compensation.profile_saved',p_job_title::text||':'||p_employment_type,
  jsonb_build_object('old',old,'pay_basis',p_pay_basis,'base_pay_cents',p_base_pay,'service_commission_bps',p_service_commission,
   'product_commission_bps',p_product_commission,'designated_client_bonus_bps',p_designated_bonus_bps,
   'minimum_attendance_minutes',p_minimum_attendance_minutes,'commission_start_service_minutes',p_commission_start_service_minutes,'active',p_active));
end $$;

create or replace function public.spa_time_entry_save(p_id uuid,p_staff uuid,p_work_date date,p_started_at timestamptz,p_ended_at timestamptz,p_break_minutes int,p_note text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid:=p_id; old jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_staff is null or p_work_date is null or p_started_at is null or p_ended_at is null or p_ended_at<=p_started_at or p_break_minutes<0
  or extract(epoch from p_ended_at-p_started_at)/60-p_break_minutes<=0 or not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'INVALID_INPUT'; end if;
 if result is null then
  insert into public.spa_time_entries(staff_id,work_date,started_at,ended_at,break_minutes,status,note,created_by)
  values(p_staff,p_work_date,p_started_at,p_ended_at,p_break_minutes,'approved',coalesce(p_note,''),auth.uid()) returning id into result;
 else
  select to_jsonb(t) into old from public.spa_time_entries t where t.id=result for update;
  if old is null then raise exception 'NOT_FOUND'; end if;
  update public.spa_time_entries set staff_id=p_staff,work_date=p_work_date,started_at=p_started_at,ended_at=p_ended_at,break_minutes=p_break_minutes,status='approved',note=coalesce(p_note,'') where id=result;
 end if;
 perform spa_private.audit('time_entry.saved',result::text,jsonb_build_object('old',old,'staff_id',p_staff,'work_date',p_work_date,'started_at',p_started_at,'ended_at',p_ended_at,'break_minutes',p_break_minutes));
 return result;
end $$;

create or replace function public.spa_time_entry_delete(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare old jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 delete from public.spa_time_entries where id=p_id returning to_jsonb(spa_time_entries) into old;
 if old is null then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('time_entry.deleted',p_id::text,old);
end $$;

create or replace function public.spa_payroll_components_save_v2(p_rule uuid,p_rates jsonb,p_tiers jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_payroll_rule_versions where id=p_rule and status='active') then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 if jsonb_typeof(p_rates)<>'array' or jsonb_typeof(p_tiers)<>'array' then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from jsonb_to_recordset(p_rates) as x(employment_type_code text,overtime_type text,start_minute int,end_minute int,multiplier_bps int)
   where x.overtime_type not in ('weekday','rest_day','national_holiday','regular_holiday') or x.start_minute<0 or x.end_minute<=x.start_minute or x.end_minute>720 or x.multiplier_bps<0 or x.multiplier_bps>100000
   or not exists(select 1 from public.spa_employment_types e where e.code=x.employment_type_code)) then raise exception 'INVALID_RATE'; end if;
 if exists(select 1 from jsonb_to_recordset(p_tiers) as x(job_title_id uuid,employment_type_code text,metric text,threshold_from bigint,threshold_to bigint,rate_bps int,calculation_mode text,service_category_id uuid)
   where x.job_title_id is null or x.employment_type_code is null or x.metric not in ('service_minutes','service_count','service_sales_cents','product_sales_cents')
    or x.threshold_from<0 or (x.threshold_to is not null and x.threshold_to<=x.threshold_from) or x.rate_bps<0 or x.rate_bps>10000
    or coalesce(x.calculation_mode,'progressive') not in ('progressive','flat')
    or not exists(select 1 from public.spa_compensation_profiles c where c.job_title_id=x.job_title_id and c.employment_type_code=x.employment_type_code)) then raise exception 'INVALID_TIER'; end if;
 delete from public.spa_payroll_overtime_rates where rule_version_id=p_rule;
 insert into public.spa_payroll_overtime_rates(rule_version_id,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps)
 select p_rule,x.employment_type_code,x.overtime_type,x.start_minute,x.end_minute,x.multiplier_bps
 from jsonb_to_recordset(p_rates) as x(employment_type_code text,overtime_type text,start_minute int,end_minute int,multiplier_bps int);
 delete from public.spa_payroll_commission_tiers where rule_version_id=p_rule;
 insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode,service_category_id)
 select p_rule,x.job_title_id,x.employment_type_code,x.metric,x.threshold_from,x.threshold_to,x.rate_bps,coalesce(x.calculation_mode,'progressive'),x.service_category_id
 from jsonb_to_recordset(p_tiers) as x(job_title_id uuid,employment_type_code text,metric text,threshold_from bigint,threshold_to bigint,rate_bps int,calculation_mode text,service_category_id uuid);
 perform spa_private.audit('payroll.components_saved',p_rule::text,jsonb_build_object('rates',jsonb_array_length(p_rates),'tiers',jsonb_array_length(p_tiers),'scope','job_title_and_employment_type'));
end $$;

-- Calculate either progressive bands or a matching flat rate. For hour/count
-- tiers, service revenue is apportioned across the measured units; revenue
-- tiers use the exact currency band amount.
create or replace function spa_private.payroll_tier_commission(
 p_rule uuid,p_job_title uuid,p_employment_type text,p_kind text,p_metric_value bigint,p_sales_cents bigint,p_fallback_bps int,p_start_value bigint,p_eligible boolean
) returns bigint language plpgsql stable security definer set search_path='' as $$
declare chosen_metric text; flat_rate int; amount numeric:=0;
begin
 if not p_eligible or coalesce(p_sales_cents,0)<=0 then return 0; end if;
 if p_kind='product' then chosen_metric:='product_sales_cents';
 else
  select t.metric into chosen_metric from public.spa_payroll_commission_tiers t
  where t.rule_version_id=p_rule and t.job_title_id=p_job_title and t.employment_type_code=p_employment_type and t.metric in ('service_minutes','service_count','service_sales_cents')
  order by case t.metric when 'service_minutes' then 1 when 'service_count' then 2 else 3 end limit 1;
 end if;
 if chosen_metric is null or not exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=p_rule and t.job_title_id=p_job_title and t.employment_type_code=p_employment_type and t.metric=chosen_metric) then
  if p_kind='service' and coalesce(p_start_value,0)>0 then
   if p_metric_value<=p_start_value or p_metric_value=0 then return 0; end if;
   return round(p_sales_cents*((p_metric_value-p_start_value)::numeric/p_metric_value)*coalesce(p_fallback_bps,0)/10000.0)::bigint;
  end if;
  return round(p_sales_cents*coalesce(p_fallback_bps,0)/10000.0)::bigint;
 end if;
 select t.rate_bps into flat_rate from public.spa_payroll_commission_tiers t
 where t.rule_version_id=p_rule and t.job_title_id=p_job_title and t.employment_type_code=p_employment_type and t.metric=chosen_metric and t.calculation_mode='flat'
  and p_metric_value>=t.threshold_from and (t.threshold_to is null or p_metric_value<t.threshold_to)
 order by t.threshold_from desc limit 1;
 if flat_rate is not null then return round(p_sales_cents*flat_rate/10000.0)::bigint; end if;
 select coalesce(sum(case when chosen_metric in ('service_sales_cents','product_sales_cents')
   then greatest(0,least(p_metric_value,coalesce(t.threshold_to,p_metric_value))-t.threshold_from)*t.rate_bps/10000.0
   else case when p_metric_value=0 then 0 else p_sales_cents*(greatest(0,least(p_metric_value,coalesce(t.threshold_to,p_metric_value))-t.threshold_from)::numeric/p_metric_value)*t.rate_bps/10000.0 end end),0)
 into amount from public.spa_payroll_commission_tiers t
 where t.rule_version_id=p_rule and t.job_title_id=p_job_title and t.employment_type_code=p_employment_type and t.metric=chosen_metric and t.calculation_mode='progressive' and p_metric_value>t.threshold_from;
 return round(amount)::bigint;
end $$;

create or replace function public.spa_payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 if version.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 return coalesce((with staff_metrics as (
  select s.id,s.name,s.job_title_id,j.name title,e.name employment_type,s.employment_type_code,s.employment_status,s.departed_on,
   coalesce(cp.pay_basis,'monthly') pay_basis,coalesce(cp.base_pay_cents,0) base_pay_cents,coalesce(cp.service_commission_bps,0) service_commission_bps,
   coalesce(cp.product_commission_bps,0) product_commission_bps,coalesce(cp.designated_client_bonus_bps,0) designated_bonus_bps,
   coalesce(cp.minimum_attendance_minutes,0) minimum_attendance_minutes,coalesce(cp.commission_start_service_minutes,0) commission_start_service_minutes,
   coalesce((select sum(greatest(0,(extract(epoch from te.ended_at-te.started_at)/60)::int-te.break_minutes)) from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved'),0)::bigint work_minutes,
   (coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint completed_count,
   (coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_count,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),0)::bigint unsettled_completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is not null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint refunded_service_count,
   (coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity*svc.duration_minutes) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services svc on svc.id=oi.service_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_minutes,
   (coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_sales_cents,
   coalesce((select count(distinct o.id) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_order_count,
   coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_sales_cents,
   (coalesce((select sum(greatest(0,ch.revenue_cents-a.tea_cents)) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and c.preferred_staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_customers c on c.id=o.customer_id where oi.staff_id=s.id and oi.item_type='service' and c.preferred_staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint designated_service_sales_cents,
   (coalesce((select count(*) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and c.preferred_staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_customers c on c.id=o.customer_id where oi.staff_id=s.id and oi.item_type='service' and c.preferred_staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint designated_clients,
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint manual_designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint deduction_cents,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_minutes,
   coalesce((select count(*) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_occurrences,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date>=date_trunc('quarter',p_to::timestamp)::date and o.work_date<=p_to and o.status='approved'),0)::bigint quarter_overtime_minutes,
   exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved' and o.overtime_type='weekday' and o.minutes>240) daily_limit_exceeded
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code
  left join public.spa_compensation_profiles cp on cp.job_title_id=s.job_title_id and cp.employment_type_code=s.employment_type_code and cp.active
  where coalesce(s.hire_date,s.created_at::date)<=p_to and ((s.employment_status='active' and s.active and s.archived_at is null)
   or (s.employment_status='departed' and s.departed_on is not null and s.departed_on>=p_from)
   or exists(select 1 from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to)
   or exists(select 1 from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved')
   or exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved')
   or exists(select 1 from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to)
   or exists(select 1 from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from))
 ), commission as (
  select m.*,
   spa_private.payroll_tier_commission(version.id,m.job_title_id,m.employment_type_code,'service',
    case when exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.job_title_id=m.job_title_id and t.employment_type_code=m.employment_type_code and t.metric='service_count') then m.service_count
         when exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.job_title_id=m.job_title_id and t.employment_type_code=m.employment_type_code and t.metric='service_sales_cents') then m.service_sales_cents else m.service_minutes end,
    m.service_sales_cents,m.service_commission_bps,m.commission_start_service_minutes,m.work_minutes>=m.minimum_attendance_minutes) calculated_service_commission_cents,
   spa_private.payroll_tier_commission(version.id,m.job_title_id,m.employment_type_code,'product',m.product_sales_cents,m.product_sales_cents,m.product_commission_bps,0,true) calculated_product_commission_cents
  from staff_metrics m
 ), base_calc as (
  select c.*,round(c.designated_service_sales_cents*c.designated_bonus_bps/10000.0)::bigint+c.manual_designated_bonus_cents designated_bonus_cents,
   case when c.pay_basis='monthly' then c.base_pay_cents when c.pay_basis='hourly' then round(c.base_pay_cents*c.work_minutes/60.0)::bigint else c.base_pay_cents*c.service_count end base_cents from commission c
 ), overtime_calc as (
  select b.*,coalesce((select round(sum((case when b.pay_basis='monthly' then (b.base_pay_cents+case when version.include_regular_commission then b.calculated_service_commission_cents+b.calculated_product_commission_cents+b.designated_bonus_cents else 0 end)/version.hourly_divisor::numeric when b.pay_basis='hourly' then b.base_pay_cents::numeric else 0 end)*greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint from public.spa_overtime_entries o join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type where o.staff_id=b.id and o.work_date between p_from and p_to and o.status='approved' and o.minutes>r.start_minute),0) overtime_cents from base_calc b
 )
 select jsonb_agg(jsonb_build_object('staff_id',id,'employee',name,'role',title,'job_title_id',job_title_id,'employment_type',employment_type,'employment_type_code',employment_type_code,'employment_status',employment_status,'departed_on',departed_on,
  'pay_basis',pay_basis,'base_pay_rate_cents',base_pay_cents,'commission_bps',service_commission_bps,'service_commission_bps',service_commission_bps,'product_commission_bps',product_commission_bps,'designated_bonus_bps',designated_bonus_bps,
  'minimum_attendance_minutes',minimum_attendance_minutes,'commission_start_service_minutes',commission_start_service_minutes,'commission_eligibility_met',work_minutes>=minimum_attendance_minutes,
  'work_minutes',work_minutes,'completed_count',completed_count,'service_count',service_count,'unsettled_completed_count',unsettled_completed_count,'refunded_service_count',refunded_service_count,'service_minutes',service_minutes,'service_sales_cents',service_sales_cents,
  'product_order_count',product_order_count,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'designated_service_sales_cents',designated_service_sales_cents,'overtime_occurrences',overtime_occurrences,'overtime_minutes',overtime_minutes,'quarter_overtime_minutes',quarter_overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',calculated_service_commission_cents,'product_commission_cents',calculated_product_commission_cents,'designated_bonus_cents',designated_bonus_cents,'overtime_cents',overtime_cents,
  'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,'total_cents',greatest(0,base_cents+calculated_service_commission_cents+calculated_product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'overtime_warning',case when quarter_overtime_minutes>version.quarterly_overtime_limit_minutes then '超過季度加班上限' when overtime_minutes>version.agreed_monthly_limit_minutes then '超過勞資會議同意月上限' when overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般月上限，需勞資會議同意' when daily_limit_exceeded then '平日單日延長工時超過 4 小時' else '' end,
  'commission_warning',case when work_minutes<minimum_attendance_minutes then '出勤未達提成門檻' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission,'compensation_source','job_title_and_employment_type','tier_scope','job_title_and_employment_type','tier_mode','progressive_or_flat','designated_bonus_basis','designated_service_revenue','service_basis','completed_and_settled','attribution_source','actual_staff')) order by name) from overtime_calc),'[]'::jsonb);
end $$;

create or replace function public.spa_payroll_admin(p_from date,p_to date,p_rule uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return jsonb_build_object(
  'staff',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) order by s.display_order,s.name) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code),'[]'),
  'job_titles',coalesce((select jsonb_agg(to_jsonb(j) order by display_order) from public.spa_job_titles j where j.active),'[]'),
  'employment_types',coalesce((select jsonb_agg(to_jsonb(e) order by display_order) from public.spa_employment_types e where e.active),'[]'),
  'compensation_profiles',coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) order by j.display_order,e.display_order) from public.spa_compensation_profiles c join public.spa_job_titles j on j.id=c.job_title_id join public.spa_employment_types e on e.code=c.employment_type_code),'[]'),
  'rules',coalesce((select jsonb_agg(to_jsonb(v) order by version_no desc) from public.spa_payroll_rule_versions v),'[]'),
  'rates',coalesce((select jsonb_agg(to_jsonb(r) order by overtime_type,employment_type_code,start_minute) from public.spa_payroll_overtime_rates r),'[]'),
  'tiers',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) order by j.display_order,e.display_order,metric,threshold_from) from public.spa_payroll_commission_tiers t join public.spa_job_titles j on j.id=t.job_title_id join public.spa_employment_types e on e.code=t.employment_type_code),'[]'),
  'time_entries',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('employee',s.name) order by t.work_date desc,t.started_at desc) from public.spa_time_entries t join public.spa_staff s on s.id=t.staff_id where t.work_date between p_from and p_to),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('employee',s.name) order by work_date desc) from public.spa_overtime_entries o join public.spa_staff s on s.id=o.staff_id where o.work_date between p_from and p_to),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('employee',s.name) order by a.created_at desc) from public.spa_payroll_adjustments a join public.spa_staff s on s.id=a.staff_id where a.period_start=p_from),'[]'),
  'runs',coalesce((select jsonb_agg(to_jsonb(r) order by period_start desc) from public.spa_payroll_runs r limit 24),'[]'),
  'preview',public.spa_payroll_preview(p_from,p_to,p_rule));
end $$;

create or replace function public.spa_staff_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid;
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select staff_id into person from public.spa_roles where user_id=auth.uid() and active;
 if person is null then return jsonb_build_object('profile',null); end if;
 return jsonb_build_object(
 'profile',(select jsonb_build_object('id',s.id,'name',s.name,'title',j.name,'employment_type',e.name,'pay_basis',c.pay_basis,'base_pay_cents',c.base_pay_cents,'commission_bps',c.service_commission_bps,'product_commission_bps',c.product_commission_bps,'designated_client_bonus_bps',c.designated_client_bonus_bps,'minimum_attendance_minutes',c.minimum_attendance_minutes,'commission_start_service_minutes',c.commission_start_service_minutes,'active',s.active) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code where s.id=person),
 'lifetime_completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed')+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid'),0),
 'metrics',jsonb_build_object(
  'completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed' and business_date between p_from and p_to)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'settled_completed',(select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'unsettled_completed',(select count(*) from public.spa_appointments a where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),
  'minutes',coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to),0)+coalesce((select sum(oi.quantity*s.duration_minutes) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services s on s.id=oi.service_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'commission_cents',coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=person and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'rating',(select round(avg(r.rating),2) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to),'reviews',(select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to)),
 'reviews',coalesce((select jsonb_agg(to_jsonb(x)) from (select r.rating,r.comment,r.reply,r.status,r.created_at,a.reference,a.service_name from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to order by r.created_at desc limit 100) x),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s where s.staff_id=person),'[]'),'daily_shifts',coalesce((select jsonb_agg(to_jsonb(d) order by business_date) from public.spa_daily_shifts d where d.staff_id=person and d.business_date between p_from and p_to),'[]'),'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where t.staff_id=person and t.ends_at>now()-interval '7 days'),'[]'));
end $$;

-- New rule versions clone title-scoped tiers as well as overtime rates.
create or replace function public.spa_payroll_rule_create(p_name text,p_effective date,p_divisor int,p_include_commission boolean,p_monthly_limit int,p_agreed_limit int,p_quarter_limit int) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; source uuid; next_no int;
begin
 perform spa_private.require_permission('payroll.manage');
 if length(btrim(coalesce(p_name,''))) not between 1 and 120 or p_effective is null or p_divisor<=0 or p_monthly_limit<=0 or p_agreed_limit<p_monthly_limit or p_quarter_limit<p_agreed_limit then raise exception 'INVALID_INPUT'; end if;
 select id into source from public.spa_payroll_rule_versions where status='active' order by version_no desc limit 1;
 select coalesce(max(version_no),0)+1 into next_no from public.spa_payroll_rule_versions;
 update public.spa_payroll_rule_versions set status='archived' where status='active';
 insert into public.spa_payroll_rule_versions(version_no,name,effective_from,status,hourly_divisor,include_regular_commission,monthly_overtime_limit_minutes,agreed_monthly_limit_minutes,quarterly_overtime_limit_minutes,created_by)
 values(next_no,btrim(p_name),p_effective,'active',p_divisor,p_include_commission,p_monthly_limit,p_agreed_limit,p_quarter_limit,auth.uid()) returning id into result;
 insert into public.spa_payroll_overtime_rates select result,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from public.spa_payroll_overtime_rates where rule_version_id=source;
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode)
 select result,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode from public.spa_payroll_commission_tiers where rule_version_id=source;
 perform spa_private.audit('payroll.rule_created',result::text,jsonb_build_object('version',next_no,'source',source)); return result;
end $$;

revoke all on function public.spa_compensation_profile_save_v2(uuid,text,text,bigint,int,int,int,int,int,boolean) from public,anon,authenticated;
grant execute on function public.spa_compensation_profile_save_v2(uuid,text,text,bigint,int,int,int,int,int,boolean) to authenticated,service_role;
revoke all on function public.spa_time_entry_save(uuid,uuid,date,timestamptz,timestamptz,int,text) from public,anon,authenticated;
grant execute on function public.spa_time_entry_save(uuid,uuid,date,timestamptz,timestamptz,int,text) to authenticated,service_role;
revoke all on function public.spa_time_entry_delete(uuid) from public,anon,authenticated;
grant execute on function public.spa_time_entry_delete(uuid) to authenticated,service_role;
revoke all on function public.spa_payroll_components_save_v2(uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.spa_payroll_components_save_v2(uuid,jsonb,jsonb) to authenticated,service_role;
revoke all on function spa_private.payroll_tier_commission(uuid,uuid,text,text,bigint,bigint,int,bigint,boolean) from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
