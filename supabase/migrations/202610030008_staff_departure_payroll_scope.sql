begin;

-- Employment status is separate from booking availability and record archival.
-- Legacy disabled seed rows remain inactive until the owner explicitly classifies
-- a real employee as active or departed.
alter table public.spa_staff add column if not exists employment_status text not null default 'active';
alter table public.spa_staff add column if not exists departed_on date;
alter table public.spa_staff add column if not exists departure_reason text not null default '';
alter table public.spa_staff drop constraint if exists spa_staff_employment_status_check;
alter table public.spa_staff add constraint spa_staff_employment_status_check check(employment_status in ('active','departed','inactive'));
alter table public.spa_staff drop constraint if exists spa_staff_departure_fields_check;
alter table public.spa_staff add constraint spa_staff_departure_fields_check check(
 (employment_status='departed' and departed_on is not null and length(btrim(departure_reason)) between 1 and 1000)
 or (employment_status<>'departed' and departed_on is null and departure_reason='')
);
update public.spa_staff set employment_status='inactive' where not active and employment_status='active';
create index if not exists spa_staff_employment_status on public.spa_staff(employment_status,departed_on);

create or replace function public.spa_staff_account_link(p_staff uuid,p_user uuid,p_role text,p_active boolean,p_reset boolean default false,p_username text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner']);perform pg_advisory_xact_lock(726002);
 if p_username is not null and lower(btrim(p_username)) !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'INVALID_USERNAME'; end if;
 if p_username is not null and exists(select 1 from public.spa_roles where lower(login_name)=lower(btrim(p_username)) and user_id<>p_user) then raise exception 'USERNAME_TAKEN'; end if;
 if p_role is null or p_role not in ('manager','receptionist','therapist') or p_active is null or p_user is null then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and archived_at is null) then raise exception 'STAFF_ARCHIVED'; end if;
 if p_active and not exists(select 1 from public.spa_staff where id=p_staff and active and employment_status='active' and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_user=auth.uid() or exists(select 1 from public.spa_roles where (user_id=p_user or staff_id=p_staff) and role='owner') then raise exception 'OWNER_PROTECTED'; end if;
 if exists(select 1 from public.spa_roles where (staff_id=p_staff and user_id<>p_user) or (user_id=p_user and staff_id is distinct from p_staff)) then raise exception 'ACCOUNT_CONFLICT'; end if;
 if exists(select 1 from public.spa_customers where auth_user_id=p_user) then raise exception 'ACCOUNT_CONFLICT'; end if;
 insert into public.spa_roles(user_id,role,staff_id,active,login_name,login_after) values(p_user,p_role,p_staff,p_active,lower(btrim(p_username)),case when p_reset then date_trunc('second',clock_timestamp())+interval '1 second' end)
 on conflict(user_id) do update set role=excluded.role,active=excluded.active,login_name=coalesce(excluded.login_name,spa_roles.login_name),login_after=case when p_reset or not p_active then date_trunc('second',clock_timestamp())+interval '1 second' else spa_roles.login_after end;
 perform spa_private.audit(case when p_reset then 'account.password_reset_requested' else 'account.access_saved' end,p_staff::text,jsonb_build_object('user_id',p_user,'role',p_role,'active',p_active,'username',p_username));
end $$;

create or replace function public.spa_staff_profile_save_v2(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 result uuid:=nullif(p_payload->>'id','')::uuid;
 old jsonb;
 services uuid[];
 work_status text:=coalesce(nullif(p_payload->>'employment_status',''),case when coalesce((p_payload->>'active')::boolean,true) then 'active' else 'inactive' end);
 leave_date date:=nullif(p_payload->>'departed_on','')::date;
 leave_reason text:=btrim(coalesce(p_payload->>'departure_reason',''));
 is_current boolean;
begin
 perform spa_private.require_permission('team.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 80 or work_status not in ('active','departed','inactive') then raise exception 'INVALID_INPUT'; end if;
 if work_status='departed' and (leave_date is null or length(leave_reason) not between 1 and 1000) then raise exception 'DEPARTURE_DETAILS_REQUIRED'; end if;
 if work_status<>'departed' then leave_date:=null;leave_reason:=''; end if;
 is_current:=work_status='active';
 select to_jsonb(s) into old from public.spa_staff s where s.id=result;
 if result is null then
  insert into public.spa_staff(name,name_en,title,specialty,bio,commission_bps,active,pay_basis,base_pay_cents,photo_url,phone,email,birth_date,address,hire_date,employment_type_code,job_title_id,is_bookable,website_visible,employment_status,departed_on,departure_reason)
  values(btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce(p_payload->>'title','調理師'),coalesce(p_payload->>'specialty',''),coalesce(p_payload->>'bio',''),
   coalesce((p_payload->>'commission_bps')::int,0),is_current,coalesce(p_payload->>'pay_basis','monthly'),nullif(p_payload->>'base_pay_cents','')::bigint,
   coalesce(p_payload->>'photo_url',''),coalesce(p_payload->>'phone',''),coalesce(p_payload->>'email',''),nullif(p_payload->>'birth_date','')::date,coalesce(p_payload->>'address',''),nullif(p_payload->>'hire_date','')::date,
   coalesce(p_payload->>'employment_type_code','full_time'),nullif(p_payload->>'job_title_id','')::uuid,is_current and coalesce((p_payload->>'is_bookable')::boolean,true),is_current and coalesce((p_payload->>'website_visible')::boolean,true),work_status,leave_date,leave_reason) returning id into result;
 else
  update public.spa_staff set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),title=coalesce(p_payload->>'title',title),specialty=coalesce(p_payload->>'specialty',''),bio=coalesce(p_payload->>'bio',''),
   commission_bps=coalesce((p_payload->>'commission_bps')::int,commission_bps),active=is_current,pay_basis=coalesce(p_payload->>'pay_basis',pay_basis),base_pay_cents=nullif(p_payload->>'base_pay_cents','')::bigint,
   photo_url=coalesce(p_payload->>'photo_url',''),phone=coalesce(p_payload->>'phone',''),email=coalesce(p_payload->>'email',''),birth_date=nullif(p_payload->>'birth_date','')::date,address=coalesce(p_payload->>'address',''),hire_date=nullif(p_payload->>'hire_date','')::date,
   employment_type_code=coalesce(p_payload->>'employment_type_code',employment_type_code),job_title_id=nullif(p_payload->>'job_title_id','')::uuid,is_bookable=is_current and coalesce((p_payload->>'is_bookable')::boolean,is_bookable),website_visible=is_current and coalesce((p_payload->>'website_visible')::boolean,website_visible),
   employment_status=work_status,departed_on=leave_date,departure_reason=leave_reason
  where id=result and archived_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
 end if;
 services:=array(select jsonb_array_elements_text(coalesce(p_payload->'services','[]'::jsonb))::uuid);
 delete from public.spa_staff_services where staff_id=result;
 insert into public.spa_staff_services(staff_id,service_id,enabled) select result,unnest(services),true;
 if not is_current then update public.spa_roles set active=false,login_after=date_trunc('second',clock_timestamp())+interval '1 second' where staff_id=result; end if;
 perform spa_private.audit('staff.profile_saved',result::text,jsonb_build_object('old',old,'new',p_payload-'services','employment_status',work_status,'departed_on',leave_date));
 return result;
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
 return coalesce((
 with staff_metrics as (
  select s.id,s.name,s.title,s.employment_type_code,s.employment_status,s.departed_on,s.pay_basis,coalesce(s.base_pay_cents,0) base_pay_cents,s.commission_bps,
   coalesce((select sum(greatest(0,(extract(epoch from te.ended_at-te.started_at)/60)::int-te.break_minutes)) from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved'),0)::bigint work_minutes,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint service_count,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),0)::bigint unsettled_completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is not null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint refunded_service_count,
   coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint service_minutes,
   coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)::bigint service_sales_cents,
   coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)::bigint checkout_commission_cents,
   coalesce((select count(distinct o.id) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_order_count,
   coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_sales_cents,
   coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint checkout_product_commission_cents,
   coalesce((select count(*) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and c.preferred_staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint designated_clients,
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint deduction_cents,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_minutes
  from public.spa_staff s
  where coalesce(s.hire_date,s.created_at::date)<=p_to
   and ((s.employment_status='active' and s.active and s.archived_at is null)
    or (s.employment_status='departed' and s.departed_on is not null and s.departed_on>=p_from)
    or exists(select 1 from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to)
    or exists(select 1 from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved')
    or exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved')
    or exists(select 1 from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to)
    or exists(select 1 from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from))
 ), commission as (
  select m.*,coalesce((select round(m.service_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t
    where t.rule_version_id=version.id and t.metric in ('service_minutes','service_count','service_sales_cents') and ((t.metric='service_minutes' and m.service_minutes>=t.threshold_from and (t.threshold_to is null or m.service_minutes<t.threshold_to))
      or (t.metric='service_count' and m.service_count>=t.threshold_from and (t.threshold_to is null or m.service_count<t.threshold_to))
      or (t.metric='service_sales_cents' and m.service_sales_cents>=t.threshold_from and (t.threshold_to is null or m.service_sales_cents<t.threshold_to)))
    order by t.threshold_from desc limit 1),m.checkout_commission_cents) service_commission_cents,
   coalesce((select round(m.product_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t
    where t.rule_version_id=version.id and t.metric='product_sales_cents' and m.product_sales_cents>=t.threshold_from and (t.threshold_to is null or m.product_sales_cents<t.threshold_to)
    order by t.threshold_from desc limit 1),m.checkout_product_commission_cents) product_commission_cents
  from staff_metrics m
 ), base_calc as (
  select c.*,case when c.pay_basis='monthly' then c.base_pay_cents when c.pay_basis='hourly' then round(c.base_pay_cents*c.work_minutes/60.0)::bigint else c.base_pay_cents*c.service_count end base_cents
  from commission c
 ), overtime_calc as (
  select b.*,coalesce((select round(sum((case when b.pay_basis='monthly' then (b.base_pay_cents+case when version.include_regular_commission then b.service_commission_cents+b.designated_bonus_cents else 0 end)/version.hourly_divisor::numeric when b.pay_basis='hourly' then b.base_pay_cents::numeric else 0 end)*greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint
   from public.spa_overtime_entries o join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type where o.staff_id=b.id and o.work_date between p_from and p_to and o.status='approved' and o.minutes>r.start_minute),0) overtime_cents
  from base_calc b
 )
 select jsonb_agg(jsonb_build_object(
  'staff_id',id,'employee',name,'role',title,'employment_type',employment_type_code,'employment_status',employment_status,'departed_on',departed_on,'pay_basis',pay_basis,'base_pay_rate_cents',base_pay_cents,'commission_bps',commission_bps,
  'work_minutes',work_minutes,'completed_count',completed_count,'service_count',service_count,'unsettled_completed_count',unsettled_completed_count,'refunded_service_count',refunded_service_count,'service_minutes',service_minutes,
  'service_sales_cents',service_sales_cents,'product_order_count',product_order_count,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'overtime_minutes',overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',service_commission_cents,'product_commission_cents',product_commission_cents,'designated_bonus_cents',designated_bonus_cents,
  'overtime_cents',overtime_cents,'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,
  'total_cents',greatest(0,base_cents+service_commission_cents+product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'overtime_warning',case when overtime_minutes>version.agreed_monthly_limit_minutes then '超過每月 54 小時上限' when overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般每月 46 小時上限' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission,'service_basis','completed_and_settled','staff_source','spa_staff','attribution_source','spa_appointments.staff_id')) order by name)
 from overtime_calc),'[]');
end $$;

create or replace function public.spa_overtime_save(p_staff uuid,p_date date,p_type text,p_minutes int,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_staff where id=p_staff and active and employment_status='active' and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_type not in ('weekday','rest_day','national_holiday','regular_holiday') or p_minutes not between 1 and 720 or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_overtime_entries(staff_id,work_date,overtime_type,minutes,reason,created_by) values(p_staff,p_date,p_type,p_minutes,btrim(p_reason),auth.uid()) returning id into result;
 perform spa_private.audit('overtime.created',result::text,jsonb_build_object('staff_id',p_staff,'date',p_date,'type',p_type,'minutes',p_minutes)); return result;
end $$;

create or replace function public.spa_payroll_adjustment_save(p_staff uuid,p_period date,p_kind text,p_cents bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_staff where id=p_staff and employment_status in ('active','departed') and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_kind not in ('bonus','allowance','deduction','designated_bonus') or p_cents<0 or length(btrim(coalesce(p_note,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_payroll_adjustments(staff_id,period_start,kind,amount_cents,note,created_by) values(p_staff,p_period,p_kind,p_cents,btrim(p_note),auth.uid()) returning id into result;
 perform spa_private.audit('payroll.adjustment_created',result::text,jsonb_build_object('staff_id',p_staff,'period',p_period,'kind',p_kind,'cents',p_cents)); return result;
end $$;

notify pgrst,'reload schema';
commit;
