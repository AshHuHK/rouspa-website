begin;

-- Preserve wage-period title/employment snapshots after later promotions.
-- The new payroll engine and versioned policy are projected through explicit
-- safe fields; raw notes, arbitrary calculation JSON and peer wages stay out.

-- Fixed, aggregate-only source contract for the AI steward. No prompt, query,
-- raw customer record, private note or attendance location enters this RPC.
create or replace function public.spa_ai_business_snapshot(p_from date default null,p_to date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 owner_scope boolean;
 person uuid;
 first_date date;
 last_date date:=coalesce(p_to,(now() at time zone 'Asia/Taipei')::date);
 earliest date;
 first_time timestamptz;
 last_time timestamptz;
 result jsonb;
 wages jsonb:='[]'::jsonb;
 safe_wages jsonb;
 wage_status text:='preview';
 run public.spa_payroll_runs;
 pending_sources boolean;
begin
 perform spa_private.require_team();
 if auth.uid() is null then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 owner_scope:=spa_private.role_name()='owner';
 if not owner_scope then
  person:=spa_private.current_staff_id();
  if person is null then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 end if;
 if not isfinite(last_date) or last_date<'1900-01-01'::date or last_date>'9999-12-30'::date
  or (p_from is not null and (not isfinite(p_from) or p_from<'1900-01-01'::date or p_from>last_date)) then
  raise exception 'INVALID_DATE';
 end if;
 -- Earliest source dates are authorized independently; employees never infer
 -- other personnel or store transaction dates from the all-history resolver.
 select min(d) into earliest from (
  select a.business_date d from public.spa_appointments a where owner_scope or a.staff_id=person
  union all select (o.paid_at at time zone 'Asia/Taipei')::date from public.spa_orders o
   where o.paid_at is not null and (owner_scope or exists(select 1 from public.spa_order_items i where i.order_id=o.id and i.staff_id=person))
  union all select t.work_date from public.spa_time_entries t where owner_scope or t.staff_id=person
  union all select a.work_date from public.spa_attendance a where owner_scope or a.staff_id=person
  union all select a.work_date from public.spa_attendance_requests a where owner_scope or a.staff_id=person
  union all select o.work_date from public.spa_overtime_entries o where owner_scope or o.staff_id=person
  union all select s.business_date from public.spa_daily_shifts s where owner_scope or s.staff_id=person
  union all select r.business_date from public.spa_staff_schedule_change_requests r where owner_scope or r.staff_id=person
  union all select s.schedule_month from public.spa_staff_schedule_submissions s where owner_scope or s.staff_id=person
  union all select (t.starts_at at time zone 'Asia/Taipei')::date from public.spa_time_off t where owner_scope or t.staff_id=person
  union all select a.period_start from public.spa_payroll_adjustments a where owner_scope or a.staff_id=person
  union all select r.period_start from public.spa_payroll_runs r where owner_scope or exists(select 1 from public.spa_payroll_items i where i.run_id=r.id and i.staff_id=person)
  union all select (c.created_at at time zone 'Asia/Taipei')::date from public.spa_customers c where owner_scope
  union all select (c.created_at at time zone 'Asia/Taipei')::date from public.spa_cash_entries c where owner_scope
  union all select (w.created_at at time zone 'Asia/Taipei')::date from public.spa_wallet_entries w where owner_scope
  union all select (p.created_at at time zone 'Asia/Taipei')::date from public.spa_packages p where owner_scope
 ) dates where d between '1900-01-01'::date and last_date;
 first_date:=coalesce(p_from,earliest,last_date);
 first_time:=first_date::timestamp at time zone 'Asia/Taipei';
 last_time:=(last_date+1)::timestamp at time zone 'Asia/Taipei';

 -- Each fact set has one row per appointment, POS line, attendance row, etc.
 -- Aggregate each independently before combining; customer/review/roster joins
 -- cannot multiply money or service quantities. Current staff_id is the actual
 -- performer after reassignment; POS line staff_id is the actual selling staff.
 with ap as materialized (
  select a.*,ch.id checkout_id,ch.refunded_at,ch.revenue_cents,
   exists(select 1 from public.spa_appointment_staff_changes sc where sc.appointment_id=a.id) reassigned
  from public.spa_appointments a left join public.spa_checkouts ch on ch.appointment_id=a.id
  where a.business_date between first_date and last_date and (owner_scope or a.staff_id=person)
 ), pos as materialized (
  select i.*,o.customer_id,o.paid_at from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
  where o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time and (owner_scope or i.staff_id=person)
 ), am as (
  select staff_id,count(*) total,count(*) filter(where status='completed') completed,
   count(*) filter(where status='completed' and checkout_id is not null and refunded_at is null) settled_completed,
   count(*) filter(where status='completed' and checkout_id is null) unsettled_completed,
   count(*) filter(where status='completed' and refunded_at is not null) refunded_completed,
   count(*) filter(where reassigned) reassigned,
   coalesce(sum(duration_minutes_snapshot) filter(where status='completed' and checkout_id is not null and refunded_at is null),0) service_minutes,
   coalesce(sum(greatest(0,revenue_cents-tea_cents)) filter(where status='completed' and checkout_id is not null and refunded_at is null),0) service_sales_cents
  from ap group by staff_id
 ), pm as (
  select staff_id,coalesce(sum(quantity) filter(where item_type='service'),0) service_quantity,
   coalesce(sum(quantity) filter(where item_type='product'),0) product_quantity,
   coalesce(sum(quantity::bigint*duration_minutes_snapshot) filter(where item_type='service'),0) service_minutes,
   coalesce(sum(net_total_cents) filter(where item_type='service'),0) service_sales_cents,
   coalesce(sum(net_total_cents) filter(where item_type='product'),0) product_sales_cents
  from pos group by staff_id
 ), rm as (
  select a.staff_id,count(*) reviews,round(avg(r.rating),2) average_rating from public.spa_reviews r join ap a on a.id=r.appointment_id group by a.staff_id
 ), roster as materialized (
  select * from public.spa_daily_shifts s where s.business_date between first_date and last_date and (owner_scope or s.staff_id=person)
 ), att as materialized (
  select * from public.spa_attendance a where a.work_date between first_date and last_date and (owner_scope or a.staff_id=person)
 ), time_entries as materialized (
  select * from public.spa_time_entries t where t.work_date between first_date and last_date and (owner_scope or t.staff_id=person)
 ), overtime as materialized (
  select * from public.spa_overtime_entries o where o.work_date between first_date and last_date and (owner_scope or o.staff_id=person)
 ), sr as materialized (
  select * from public.spa_staff_schedule_change_requests r where r.business_date between first_date and last_date and (owner_scope or r.staff_id=person)
 ), submissions as materialized (
  select * from public.spa_staff_schedule_submissions s where s.schedule_month<=last_date and (s.schedule_month+interval '1 month')::date>first_date and (owner_scope or s.staff_id=person)
 ) select jsonb_build_object(
  'schema_version',1,'scope',case when owner_scope then 'store' else 'self' end,
  'period',jsonb_build_object('from',first_date,'to',last_date),'earliest_date',earliest,
  'snapshot_date',(now() at time zone 'Asia/Taipei')::date,
  'units',jsonb_build_object('money','cents','time','minutes','timezone','Asia/Taipei'),
  'source_contract',jsonb_build_object('aggregation','exact_all_authorized_records','appointments','business_date_actual_staff','sales','completed_unrefunded_appointment_services_and_paid_pos_net_lines','pos','taipei_paid_date_actual_selling_staff','attendance','approved_time_entries_floor_minutes','current','current_database_snapshot_not_period_totals','schedule','dated_overrides_not_inferred_weekly_coverage','refunds','checkout_refunded_date_and_cash_ledger;pos_refund_date_unavailable','customers','current_membership_and_archive_status;dormant_90_days_since_completed_or_paid_visit'),
  'bookings',(select jsonb_build_object('total',count(*),'pending',count(*) filter(where status='pending'),'confirmed',count(*) filter(where status='confirmed'),'checked_in',count(*) filter(where status='checked_in'),'in_service',count(*) filter(where status='in_service'),'completed',count(*) filter(where status='completed'),'cancelled',count(*) filter(where status='cancelled'),'no_show',count(*) filter(where status='no_show'),'reassigned',count(*) filter(where reassigned),'settled_completed',count(*) filter(where status='completed' and checkout_id is not null and refunded_at is null),'unsettled_completed',count(*) filter(where status='completed' and checkout_id is null),'refunded_completed',count(*) filter(where status='completed' and refunded_at is not null)) from ap),
  'sales',jsonb_build_object(
   'appointment_service_cents',(select coalesce(sum(service_sales_cents),0) from am),
   'appointment_tea_cents',(select coalesce(sum(least(revenue_cents,tea_cents)),0) from ap where status='completed' and checkout_id is not null and refunded_at is null),
   'pos_service_cents',(select coalesce(sum(service_sales_cents),0) from pm),'pos_product_cents',(select coalesce(sum(product_sales_cents),0) from pm),
   'pos_service_quantity',(select coalesce(sum(service_quantity),0) from pm),'pos_product_quantity',(select coalesce(sum(product_quantity),0) from pm),
   'service_minutes',(select coalesce(sum(service_minutes),0) from am)+(select coalesce(sum(service_minutes),0) from pm),
   'total_net_cents',(select coalesce(sum(revenue_cents),0) from ap where status='completed' and checkout_id is not null and refunded_at is null)+(select coalesce(sum(net_total_cents),0) from pos)),
  'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'title',coalesce(j.name,s.title),'employment_status',s.employment_status,'active',s.active and s.employment_status='active' and s.archived_at is null,
   'completed',coalesce(am.completed,0)+coalesce(pm.service_quantity,0),'settled_completed',coalesce(am.settled_completed,0)+coalesce(pm.service_quantity,0),'unsettled_completed',coalesce(am.unsettled_completed,0),'refunded_completed',coalesce(am.refunded_completed,0),'service_minutes',coalesce(am.service_minutes,0)+coalesce(pm.service_minutes,0),'service_sales_cents',coalesce(am.service_sales_cents,0)+coalesce(pm.service_sales_cents,0),'product_sales_cents',coalesce(pm.product_sales_cents,0),'product_quantity',coalesce(pm.product_quantity,0),'pos_service_quantity',coalesce(pm.service_quantity,0),'reassigned',coalesce(am.reassigned,0),'reviews',coalesce(rm.reviews,0),'average_rating',rm.average_rating) order by s.display_order,s.id)
   from public.spa_staff s left join public.spa_job_titles j on j.id=s.job_title_id left join am on am.staff_id=s.id left join pm on pm.staff_id=s.id left join rm on rm.staff_id=s.id where owner_scope or s.id=person),'[]'::jsonb),
  'scheduling',jsonb_build_object('daily_rows',(select count(*) from roster),'working_rows',(select count(*) from roster where is_working),'off_rows',(select count(*) from roster where not is_working),'planned_minutes',(select coalesce(sum(end_minute-start_minute),0) from roster where is_working),'time_off_count',(select count(*) from public.spa_time_off t where t.starts_at<last_time and t.ends_at>first_time and (owner_scope or t.staff_id=person)),'requests_pending',(select count(*) from sr where status='pending'),'requests_approved',(select count(*) from sr where status='approved'),'requests_rejected',(select count(*) from sr where status='rejected'),'submissions',(select count(*) from submissions),'submitted_staff',(select count(distinct staff_id) from submissions),'submission_months',(select count(distinct schedule_month) from submissions)),
  'attendance',(select jsonb_build_object('approved',count(*) filter(where status='approved'),'open',count(*) filter(where status='open'),'pending',count(*) filter(where status='pending'),'rejected',count(*) filter(where status='rejected'),'missing_clock_out',count(*) filter(where clock_in is not null and clock_out is null),'requests_pending',(select count(*) from public.spa_attendance_requests r where r.status='pending' and r.work_date between first_date and last_date and (owner_scope or r.staff_id=person)),'approved_work_minutes',(select coalesce(sum(greatest(0,floor(extract(epoch from ended_at-started_at)/60)::bigint-break_minutes)),0) from time_entries where status='approved'),'draft_time_entries',(select count(*) from time_entries where status='draft'),'approved_overtime_minutes',(select coalesce(sum(minutes),0) from overtime where status='approved'),'draft_overtime_entries',(select count(*) from overtime where status='draft')) from att)
 ) into result;

 if owner_scope then
  result:=result||jsonb_build_object(
   'finances',(select jsonb_build_object('cash_in_cents',coalesce(sum(amount_cents) filter(where amount_cents>0),0),'cash_out_cents',coalesce(-sum(amount_cents) filter(where amount_cents<0),0),'cash_net_cents',coalesce(sum(amount_cents),0),'expenses_cents',coalesce(-sum(amount_cents) filter(where category='expense'),0),'cash_refunds_cents',coalesce(-sum(amount_cents) filter(where category='refund'),0),'checkout_refunds_cents',(select coalesce(sum(revenue_cents),0) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),'checkout_refund_count',(select count(*) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),'pos_refunded_orders_by_paid_date',(select count(*) from public.spa_orders where status='refunded' and paid_at>=first_time and paid_at<last_time)) from public.spa_cash_entries where created_at>=first_time and created_at<last_time),
   'customers',(with visits as (
    select customer_id,business_date d from public.spa_appointments where status='completed'
    union all select customer_id,(paid_at at time zone 'Asia/Taipei')::date from public.spa_orders where status='paid' and customer_id is not null
   ), last_visits as (select customer_id,max(d) last_visit from visits group by customer_id)
   select jsonb_build_object('current_total',count(*),'current_active',count(*) filter(where c.status='active' and c.archived_at is null),'current_archived',count(*) filter(where c.archived_at is not null),'current_members',count(*) filter(where c.customer_type='member' and c.status='active' and c.archived_at is null),'current_guests',count(*) filter(where c.customer_type='guest' and c.status='active' and c.archived_at is null),'new_in_period',count(*) filter(where c.created_at>=first_time and c.created_at<last_time),'visited_in_period',(select count(distinct customer_id) from visits where d between first_date and last_date),'current_dormant_90_days',count(*) filter(where c.status='active' and c.archived_at is null and coalesce(v.last_visit,(c.created_at at time zone 'Asia/Taipei')::date)<(now() at time zone 'Asia/Taipei')::date-90)) from public.spa_customers c left join last_visits v on v.customer_id=c.id),
   'current',jsonb_build_object('wallet_liability_cents',(select coalesce(sum(amount_cents),0) from public.spa_wallet_entries),'package_liability_cents',(select coalesce(sum(p.paid_cents-coalesce(used.used_cents,0)),0) from public.spa_packages p left join (select ch.package_id,sum(ch.revenue_cents-a.tea_cents) used_cents from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.package_id is not null and ch.refunded_at is null group by ch.package_id) used on used.package_id=p.id),'active_staff',(select count(*) from public.spa_staff where active and employment_status='active' and archived_at is null),'departed_staff',(select count(*) from public.spa_staff where employment_status='departed'),'active_services',(select count(*) from public.spa_services where active and status='active'),'active_products',(select count(*) from public.spa_products where status='active'),'inventory_units',(select coalesce(sum(delta),0) from public.spa_inventory_entries))
  );
 end if;

 pending_sources:=((result->'attendance'->>'open')::bigint+(result->'attendance'->>'pending')::bigint+(result->'attendance'->>'requests_pending')::bigint+(result->'attendance'->>'draft_time_entries')::bigint+(result->'attendance'->>'draft_overtime_entries')::bigint+(result->'bookings'->>'unsettled_completed')::bigint)>0;
 select * into run from public.spa_payroll_runs where period_start=first_date and period_end=last_date;
 if last_date-first_date>366 then wage_status:='unsupported_range';
 elsif run.status='finalized' then
  wages:=coalesce(run.calculation_snapshot->'rows','[]'::jsonb);wage_status:='finalized';
 else
  begin wages:=spa_private.payroll_preview(first_date,last_date,null);
  exception when others then
   if sqlerrm='PAYROLL_RULE_REQUIRED' then wage_status:='rule_unavailable';else raise;end if;
  end;
 end if;
 -- Re-project even trusted saved payroll JSON: snapshots can contain rules,
 -- notes or additional fields. No arbitrary snapshot content passes through.
 select coalesce(jsonb_agg(jsonb_build_object('staff_id',x.staff_id,'employee',x.employee,'role',x.role,'employment_type',x.employment_type,'employment_type_code',x.employment_type_code,'pay_basis',x.pay_basis,'work_category',x.work_category,'job_title_code',x.job_title_code,'classification_pending',x.classification_pending,'compensation_configured',x.compensation_configured,'commission_policy_ready',x.commission_policy_ready,'commission_eligibility_met',x.commission_eligibility_met,'service_commission_mode',x.service_commission_mode,'contractor_count_scope',x.contractor_count_scope,'service_policy_status',x.service_policy_status,'has_overtime_warning',length(coalesce(x.overtime_warning,''))>0,'has_commission_warning',length(coalesce(x.commission_warning,''))>0,'base_pay_rate_cents',x.base_pay_rate_cents,'work_minutes',x.work_minutes,'completed_count',x.completed_count)||jsonb_build_object('service_minutes',x.service_minutes,'service_count',x.service_count,'unsettled_completed_count',x.unsettled_completed_count,'refunded_service_count',x.refunded_service_count,'service_sales_cents',x.service_sales_cents,'product_sales_cents',x.product_sales_cents,'service_commission_bps',x.service_commission_bps,'product_commission_bps',x.product_commission_bps,'designated_bonus_bps',x.designated_bonus_bps,'self_sourced_commission_bps',x.self_sourced_commission_bps,'minimum_attendance_minutes',x.minimum_attendance_minutes,'minimum_service_minutes',x.minimum_service_minutes,'commission_start_service_minutes',x.commission_start_service_minutes,'overtime_minutes',x.overtime_minutes,'unpriced_overtime_minutes',x.unpriced_overtime_minutes,'base_cents',x.base_cents,'service_commission_cents',x.service_commission_cents,'product_commission_cents',x.product_commission_cents,'designated_bonus_cents',x.designated_bonus_cents,'overtime_cents',x.overtime_cents)||jsonb_build_object('bonus_cents',x.bonus_cents,'allowance_cents',x.allowance_cents,'deduction_cents',x.deduction_cents,'total_cents',x.total_cents,'contract_started_on',x.contract_started_on,'contract_start_pending',x.contract_start_pending)||jsonb_build_object('calculation',jsonb_build_object('rule_version',x.calculation->'rule_version','hourly_divisor',x.calculation->'hourly_divisor','include_regular_commission',x.calculation->'include_regular_commission','total_floor_zero',x.calculation->'total_floor_zero','calculation_engine',x.calculation->'calculation_engine','profile_source',x.calculation->'profile_source','tier_mode',x.calculation->'tier_mode','tier_reset',x.calculation->'tier_reset','contractor_count_scope',x.calculation->'contractor_count_scope','product_commission_basis',x.calculation->'product_commission_basis','self_sourced_basis',x.calculation->'self_sourced_basis','service_basis',x.calculation->'service_basis','attribution_source',x.calculation->'attribution_source','adjustment_date_basis',x.calculation->'adjustment_date_basis','component_total_before_floor_cents',x.calculation->'component_total_before_floor_cents')) order by x.staff_id),'[]'::jsonb) into safe_wages
 from jsonb_to_recordset(wages) x(staff_id uuid,employee text,role text,employment_type text,employment_type_code text,pay_basis text,work_category text,job_title_code text,classification_pending boolean,compensation_configured boolean,commission_policy_ready boolean,commission_eligibility_met boolean,service_commission_mode text,contractor_count_scope text,service_policy_status text,contract_started_on date,contract_start_pending boolean,overtime_warning text,commission_warning text,base_pay_rate_cents bigint,work_minutes bigint,completed_count bigint,service_minutes bigint,service_count bigint,unsettled_completed_count bigint,refunded_service_count bigint,service_sales_cents bigint,product_sales_cents bigint,service_commission_bps bigint,product_commission_bps bigint,designated_bonus_bps bigint,self_sourced_commission_bps bigint,minimum_attendance_minutes bigint,minimum_service_minutes bigint,commission_start_service_minutes bigint,overtime_minutes bigint,unpriced_overtime_minutes bigint,base_cents bigint,service_commission_cents bigint,product_commission_cents bigint,designated_bonus_cents bigint,overtime_cents bigint,bonus_cents bigint,allowance_cents bigint,deduction_cents bigint,total_cents bigint,calculation jsonb)
 where owner_scope or x.staff_id=person;
 return result||jsonb_build_object('payroll',jsonb_build_object('status',wage_status,'pending_sources',pending_sources,'needs_recalculation',coalesce(run.needs_recalculation,false),'total_cents',case when wage_status in ('preview','finalized') then (select coalesce(sum((w->>'total_cents')::bigint),0) from jsonb_array_elements(safe_wages) w) end,'rows',safe_wages));
end $$;

revoke all on function public.spa_ai_business_snapshot(date,date) from public,anon,authenticated,service_role;
grant execute on function public.spa_ai_business_snapshot(date,date) to authenticated;
notify pgrst,'reload schema';
commit;
