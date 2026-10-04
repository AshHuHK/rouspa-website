begin;

-- period_start is retained for compatibility, but represents the date on which
-- an adjustment is included. Payroll reads every adjustment inside the selected
-- date range so changing the range start cannot make an in-range record vanish.
comment on column public.spa_payroll_adjustments.period_start is
 'Adjustment effective date. Included when it falls inside the selected payroll range.';

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
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint manual_designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint deduction_cents,
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
   or exists(select 1 from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to))
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
  'product_order_count',product_order_count,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'designated_service_sales_cents',designated_service_sales_cents,'manual_designated_bonus_cents',manual_designated_bonus_cents,'overtime_occurrences',overtime_occurrences,'overtime_minutes',overtime_minutes,'quarter_overtime_minutes',quarter_overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',calculated_service_commission_cents,'product_commission_cents',calculated_product_commission_cents,'designated_bonus_cents',designated_bonus_cents,'overtime_cents',overtime_cents,
  'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,'total_cents',greatest(0,base_cents+calculated_service_commission_cents+calculated_product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'overtime_warning',case when quarter_overtime_minutes>version.quarterly_overtime_limit_minutes then '超過季度加班上限' when overtime_minutes>version.agreed_monthly_limit_minutes then '超過勞資會議同意月上限' when overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般月上限，需勞資會議同意' when daily_limit_exceeded then '平日單日延長工時超過 4 小時' else '' end,
  'commission_warning',case when work_minutes<minimum_attendance_minutes then '出勤未達提成門檻' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission,'compensation_source','job_title_and_employment_type','tier_scope','job_title_and_employment_type','tier_mode','progressive_or_flat','designated_bonus_basis','designated_service_revenue','service_basis','completed_and_settled','attribution_source','actual_staff','adjustment_date_basis','selected_range','money_unit','cents','percentage_unit','basis_points','time_unit','minutes','component_total_before_floor_cents',base_cents+calculated_service_commission_cents+calculated_product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents,'total_floor_zero',true)) order by name) from overtime_calc),'[]'::jsonb);
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
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('employee',s.name) order by a.created_at desc) from public.spa_payroll_adjustments a join public.spa_staff s on s.id=a.staff_id where a.period_start between p_from and p_to),'[]'),
  'runs',coalesce((select jsonb_agg(to_jsonb(r) order by period_start desc) from public.spa_payroll_runs r limit 24),'[]'),
  'preview',public.spa_payroll_preview(p_from,p_to,p_rule));
end $$;

create or replace function public.spa_payroll_staff_detail(p_staff uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'NOT_FOUND'; end if;
 return jsonb_build_object(
  'profile',(select to_jsonb(s)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code where s.id=p_staff),
  'services',coalesce((select jsonb_agg(to_jsonb(x) order by x.business_date,x.starts_at) from (select a.id,a.reference,a.business_date,a.starts_at,a.service_name_snapshot service_name,a.duration_minutes_snapshot service_minutes,case when ch.id is null then 'unsettled' when ch.refunded_at is not null then 'refunded' else 'settled' end settlement_status,ch.revenue_cents,ch.commission_cents,(select count(*) from public.spa_reviews r where r.appointment_id=a.id) review_count from public.spa_appointments a left join public.spa_checkouts ch on ch.appointment_id=a.id where a.staff_id=p_staff and a.business_date between p_from and p_to and a.status='completed') x),'[]'),
  'pos_services',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.line_total_cents,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=p_staff and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'product_orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.line_total_cents,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=p_staff and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'time_entries',coalesce((select jsonb_agg(to_jsonb(t) order by work_date,started_at) from public.spa_time_entries t where t.staff_id=p_staff and t.work_date between p_from and p_to and t.status='approved'),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o) order by work_date) from public.spa_overtime_entries o where o.staff_id=p_staff and o.work_date between p_from and p_to and o.status='approved'),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a) order by created_at) from public.spa_payroll_adjustments a where a.staff_id=p_staff and a.period_start between p_from and p_to),'[]'));
end $$;

create or replace function public.spa_payroll_adjustment_save(p_staff uuid,p_period date,p_kind text,p_cents bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_staff where id=p_staff and employment_status in ('active','departed') and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_period is null or p_kind not in ('bonus','allowance','deduction','designated_bonus') or p_cents<0 or length(btrim(coalesce(p_note,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_payroll_adjustments(staff_id,period_start,kind,amount_cents,note,created_by)
 values(p_staff,p_period,p_kind,p_cents,btrim(p_note),auth.uid()) returning id into result;
 perform spa_private.audit('payroll.adjustment_created',result::text,jsonb_build_object('staff_id',p_staff,'effective_date',p_period,'kind',p_kind,'cents',p_cents));
 return result;
end $$;

revoke all on function public.spa_payroll_adjustment_save(uuid,date,text,bigint,text) from public,anon,authenticated;
grant execute on function public.spa_payroll_adjustment_save(uuid,date,text,bigint,text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
