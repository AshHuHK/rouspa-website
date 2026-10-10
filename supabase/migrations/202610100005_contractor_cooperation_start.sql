begin;

-- Cooperation has its own start date; employment tenure is not an assumption
-- about when a full-time employee began a contractor arrangement.
alter table public.spa_staff add column if not exists contract_started_on date;
create or replace function spa_private.staff_cooperation_dates_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.contract_started_on is not null and (new.contract_started_on<'1900-01-01'::date or (new.hire_date is not null and new.contract_started_on<new.hire_date) or (new.departed_on is not null and new.contract_started_on>new.departed_on)) then raise exception 'INVALID_CONTRACT_COOPERATION_DATE'; end if;
 return new;
end $$;
create trigger spa_staff_cooperation_dates_guard before insert or update of contract_started_on,hire_date,departed_on on public.spa_staff for each row execute function spa_private.staff_cooperation_dates_guard();
create trigger spa_payroll_cooperation_draft_changed after update of contract_started_on on public.spa_staff for each statement execute function spa_private.payroll_draft_changed();

alter function public.spa_staff_profile_save_v2(jsonb) set schema spa_private;
alter function spa_private.spa_staff_profile_save_v2(jsonb) rename to staff_profile_save_before_cooperation_20261010;
create or replace function public.spa_staff_profile_save_v2(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid; old_date date; supplied boolean:=coalesce(p_payload?'contract_started_on',false); new_date date:=nullif(p_payload->>'contract_started_on','')::date;
begin
 perform spa_private.require_permission('team.manage');
 select contract_started_on into old_date from public.spa_staff where id=nullif(p_payload->>'id','')::uuid;
 -- Set the proposed date before the legacy profile update so a valid change of
 -- employment dates is checked against the new cooperation date, atomically.
 if supplied and nullif(p_payload->>'id','') is not null then
  update public.spa_staff set contract_started_on=null where id=(p_payload->>'id')::uuid;
 end if;
 result:=spa_private.staff_profile_save_before_cooperation_20261010(p_payload);
 if supplied then
  update public.spa_staff set contract_started_on=new_date where id=result;
  perform spa_private.audit('staff.cooperation_date_saved',result::text,jsonb_build_object('old_date',old_date,'contract_started_on',new_date));
 end if;
 return result;
end $$;

create or replace function spa_private.payroll_ordered_commissions(p_staff uuid,p_from date,p_to date,p_rule uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare profile public.spa_payroll_version_profiles; title public.spa_job_titles; chosen_metric text; units jsonb; result jsonb:='[]'; item jsonb; segments jsonb; unit_metric bigint; before_metric bigint; after_metric bigint; income bigint; amount bigint; designated bigint; eligible boolean; attendance bigint; service_minutes bigint; month_key text; month_metrics jsonb:='{}'; month_service_metrics jsonb:='{}'; before_service_minutes bigint; after_service_minutes bigint; month_facts jsonb; lifetime_count bigint:=0; contract_start date; band record; lo bigint; hi bigint; net_segment bigint;
begin
 select j.* into title from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=p_staff;
 select p.* into profile from public.spa_payroll_version_profiles p join public.spa_staff s on s.job_title_id=p.job_title_id and s.employment_type_code=p.employment_type_code where p.rule_version_id=p_rule and s.id=p_staff;
 if profile.job_title_id is null then return result; end if;
 select contract_started_on into contract_start from public.spa_staff where id=p_staff;
 if profile.employment_type_code='contractor' and contract_start is null then return result; end if;
 select metric into chosen_metric from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric in ('service_minutes','service_count','service_sales_cents') order by case metric when 'service_minutes' then 1 when 'service_count' then 2 else 3 end limit 1;
 chosen_metric:=coalesce(chosen_metric,'service_minutes');
 select coalesce(jsonb_agg(to_jsonb(q) order by event_time,source_kind,source_id,unit_index),'[]') into units from (
  select 'appointment'::text source_kind,a.id source_id,a.reference,a.business_date date,a.starts_at event_time,1 unit_index,1 quantity,a.duration_minutes_snapshot duration_minutes,
   greatest(0,ch.revenue_cents-a.tea_cents)::bigint net_cents,ch.designated_client_snapshot designated,ch.self_sourced_client_snapshot self_sourced
  from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null
  where a.staff_id=p_staff and a.status='completed' and a.business_date<=p_to
   and (profile.employment_type_code<>'contractor' or a.business_date>=contract_start)
   and (profile.contractor_count_scope='lifetime' or a.business_date>=date_trunc('month',p_from::timestamp)::date)
  union all
  select 'pos_service',i.id,o.reference,(o.paid_at at time zone 'Asia/Taipei')::date,o.paid_at,n,1,i.duration_minutes_snapshot,
   (floor(i.net_total_cents*n::numeric/i.quantity)-floor(i.net_total_cents*(n-1)::numeric/i.quantity))::bigint,i.designated_client_snapshot,i.self_sourced_client_snapshot
  from public.spa_order_items i join public.spa_orders o on o.id=i.order_id cross join lateral generate_series(1,i.quantity)n
  where i.staff_id=p_staff and i.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date<=p_to
   and (profile.employment_type_code<>'contractor' or (o.paid_at at time zone 'Asia/Taipei')::date>=contract_start)
   and (profile.contractor_count_scope='lifetime' or (o.paid_at at time zone 'Asia/Taipei')::date>=date_trunc('month',p_from::timestamp)::date)
 )q;
 select coalesce(jsonb_object_agg(month_label,jsonb_build_object('service_minutes',minutes,'work_minutes',
  (select coalesce(sum(greatest(0,floor(extract(epoch from ended_at-started_at)/60)::int-break_minutes)),0) from public.spa_time_entries where staff_id=p_staff and status='approved' and work_date<=p_to and substring(work_date::text from 1 for 7)=m.month_label))),'{}') into month_facts
 from (select substring(x->>'date' from 1 for 7) as month_label,sum((x->>'duration_minutes')::bigint)minutes from jsonb_array_elements(units)x group by 1)m;
 for item in select value from jsonb_array_elements(units) loop
  month_key:=substring(item->>'date' from 1 for 7); income:=(item->>'net_cents')::bigint;
  unit_metric:=case chosen_metric when 'service_count' then 1 when 'service_sales_cents' then income else (item->>'duration_minutes')::bigint end;
  before_metric:=case when chosen_metric='service_count' and profile.contractor_count_scope='lifetime' then lifetime_count else coalesce((month_metrics->>month_key)::bigint,0) end;
  after_metric:=before_metric+unit_metric;
  month_metrics:=jsonb_set(month_metrics,array[month_key],to_jsonb(after_metric),true); lifetime_count:=lifetime_count+1;
  before_service_minutes:=coalesce((month_service_metrics->>month_key)::bigint,0); after_service_minutes:=before_service_minutes+(item->>'duration_minutes')::bigint;
  month_service_metrics:=jsonb_set(month_service_metrics,array[month_key],to_jsonb(after_service_minutes),true);
  if (item->>'date')::date not between p_from and p_to then continue; end if;
  attendance:=coalesce((month_facts->month_key->>'work_minutes')::bigint,0); service_minutes:=coalesce((month_facts->month_key->>'service_minutes')::bigint,0);
  eligible:=title.work_category='technician' and not title.legacy and profile.active and profile.service_policy_status='confirmed' and attendance>=profile.minimum_attendance_minutes and case when profile.employment_type_code='part_time' then service_minutes>profile.minimum_service_minutes else service_minutes>=profile.minimum_service_minutes end;
  amount:=0; designated:=0; segments:='[]';
  if eligible then
   if (item->>'self_sourced')::boolean and profile.employment_type_code='contractor' then
    amount:=round(income*profile.self_sourced_commission_bps/10000.0)::bigint;
    segments:=jsonb_build_array(jsonb_build_object('basis','self_sourced','net_cents',income,'rate_bps',profile.self_sourced_commission_bps,'commission_cents',amount));
   elsif profile.service_commission_mode='flat' then
    if after_service_minutes>before_service_minutes then
     lo:=least(after_service_minutes,greatest(before_service_minutes,profile.commission_start_service_minutes));
     net_segment:=income-floor(income*(lo-before_service_minutes)::numeric/(after_service_minutes-before_service_minutes))::bigint;
     amount:=round(net_segment*profile.service_commission_bps/10000.0)::bigint;
     if lo>before_service_minutes then segments:=jsonb_build_array(jsonb_build_object('basis','flat_salary_covered','metric','service_minutes','from',before_service_minutes,'to',lo,'net_cents',income-net_segment,'rate_bps',0,'commission_cents',0)); end if;
     if after_service_minutes>lo then segments:=segments||jsonb_build_array(jsonb_build_object('basis','flat','metric','service_minutes','from',lo,'to',after_service_minutes,'net_cents',net_segment,'rate_bps',profile.service_commission_bps,'commission_cents',amount)); end if;
    end if;
   elsif profile.service_commission_mode='ordered_tiers' and unit_metric>0 then
    for band in select * from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric=chosen_metric and calculation_mode='progressive' and threshold_from<after_metric and coalesce(threshold_to,after_metric)>before_metric order by threshold_from,id loop
     lo:=greatest(before_metric,band.threshold_from); hi:=least(after_metric,coalesce(band.threshold_to,after_metric));
     net_segment:=(floor(income*(hi-before_metric)::numeric/unit_metric)-floor(income*(lo-before_metric)::numeric/unit_metric))::bigint;
     amount:=amount+round(net_segment*band.rate_bps/10000.0)::bigint;
     segments:=segments||jsonb_build_array(jsonb_build_object('tier_id',band.id,'metric',chosen_metric,'from',lo,'to',hi,'net_cents',net_segment,'rate_bps',band.rate_bps,'commission_cents',round(net_segment*band.rate_bps/10000.0)::bigint));
    end loop;
    if not exists(select 1 from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric=chosen_metric) and after_metric>profile.commission_start_service_minutes then
     net_segment:=(income-floor(income*greatest(0,profile.commission_start_service_minutes-before_metric)::numeric/unit_metric))::bigint;
     amount:=round(net_segment*profile.service_commission_bps/10000.0)::bigint;
     segments:=jsonb_build_array(jsonb_build_object('basis','fallback','net_cents',net_segment,'rate_bps',profile.service_commission_bps,'commission_cents',amount));
    end if;
   end if;
   if (item->>'designated')::boolean and not ((item->>'self_sourced')::boolean and profile.employment_type_code='contractor') then designated:=round(income*profile.designated_client_bonus_bps/10000.0)::bigint; end if;
  end if;
  result:=result||jsonb_build_array(item||jsonb_build_object('metric',chosen_metric,'metric_from',before_metric,'metric_to',after_metric,'service_minutes_from',before_service_minutes,'service_minutes_to',after_service_minutes,'eligible',eligible,'qualification_work_minutes',attendance,'qualification_service_minutes',service_minutes,'service_commission_cents',amount,'designated_bonus_cents',designated,'commission_segments',segments));
 end loop;
 return result;
end $$;

create or replace function spa_private.payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions; profile public.spa_payroll_version_profiles; title public.spa_job_titles;
 legacy_rows jsonb; row jsonb; result jsonb:='[]'; lines jsonb; base bigint; service bigint; product bigint; designated bigint; overtime bigint; unpriced bigint;
 overtime_hourly numeric; total bigint; configured boolean; ready boolean; warning text; work bigint; service_minutes bigint; eligibility boolean; qualification_work bigint; qualification_service bigint; source_totals jsonb; contract_start date; contract_pending boolean; designated_count bigint; designated_sales bigint;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 if version.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 legacy_rows:=spa_private.payroll_preview_legacy_20261010(p_from,p_to,version.id);
 if version.calculation_engine<>'ordered_v2' then return legacy_rows; end if;
 for row in select value from jsonb_array_elements(legacy_rows) loop
  select * into title from public.spa_job_titles where id=(row->>'job_title_id')::uuid;
  select * into profile from public.spa_payroll_version_profiles where rule_version_id=version.id and job_title_id=title.id and employment_type_code=row->>'employment_type_code';
  work:=(row->>'work_minutes')::bigint; service_minutes:=(row->>'service_minutes')::bigint;
  configured:=profile.job_title_id is not null and profile.active;
  select contract_started_on into contract_start from public.spa_staff where id=(row->>'staff_id')::uuid;
  contract_pending:=profile.employment_type_code='contractor' and contract_start is null;
  ready:=configured and not title.legacy and not contract_pending and profile.service_policy_status='confirmed';
  warning:=case when title.legacy then '舊職稱待店主確認新職級；目前金額僅供核對，不可正式結算' when not configured then '職稱薪資未設定／未啟用' when contract_pending then '承攬合作開始日期待店主確認；不猜到職日，不能正式結算' when profile.service_policy_status<>'confirmed' then '服務抽成規則待確認' when work<profile.minimum_attendance_minutes then '核准出勤未達服務抽成門檻' when service_minutes<profile.minimum_service_minutes then '服務時數未達抽成門檻' else '' end;
  lines:=case when title.legacy then '[]'::jsonb else spa_private.payroll_ordered_commissions((row->>'staff_id')::uuid,p_from,p_to,version.id) end;
  source_totals:=spa_private.payroll_source_totals(spa_private.payroll_source_records((row->>'staff_id')::uuid,p_from,p_to));
  designated_count:=(source_totals->>'designated_clients')::bigint; designated_sales:=(source_totals->>'designated_service_sales_cents')::bigint;
  select coalesce(max((x->>'qualification_work_minutes')::bigint),work),coalesce(max((x->>'qualification_service_minutes')::bigint),service_minutes) into qualification_work,qualification_service from jsonb_array_elements(lines)x;
  eligibility:=ready and (title.work_category<>'technician' or case when jsonb_array_length(lines)>0 then not exists(select 1 from jsonb_array_elements(lines)x where not (x->>'eligible')::boolean) else qualification_work>=profile.minimum_attendance_minutes and case when profile.employment_type_code='part_time' then qualification_service>profile.minimum_service_minutes else qualification_service>=profile.minimum_service_minutes end end);
  warning:=case when title.legacy then '舊職稱待店主確認新職級；目前金額僅供核對，不可正式結算' when not configured then '職稱薪資未設定／未啟用' when contract_pending then '承攬合作開始日期待店主確認；不猜到職日，不能正式結算' when profile.service_policy_status<>'confirmed' then '服務抽成規則待確認' when not eligibility then '部分月份核准出勤／服務時數未達抽成門檻' else '' end;
  if title.legacy then service:=(row->>'service_commission_cents')::bigint; designated:=round(designated_sales*coalesce(profile.designated_client_bonus_bps,0)/10000.0)::bigint+coalesce((row->>'manual_designated_bonus_cents')::bigint,0);
  else
   select coalesce(sum((x->>'service_commission_cents')::bigint),0),coalesce(sum((x->>'designated_bonus_cents')::bigint),0) into service,designated from jsonb_array_elements(lines)x;
   designated:=designated+coalesce((row->>'manual_designated_bonus_cents')::bigint,0);
  end if;
  select coalesce(sum(i.commission_cents),0) into product from public.spa_order_items i join public.spa_orders o on o.id=i.order_id where i.staff_id=(row->>'staff_id')::uuid and i.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to;
  base:=case when not configured then 0 when profile.pay_basis='monthly' then profile.base_pay_cents when profile.pay_basis='hourly' then round(profile.base_pay_cents*work/60.0)::bigint else profile.base_pay_cents*(row->>'service_count')::bigint end;
  overtime_hourly:=case when profile.pay_basis='monthly' then (profile.base_pay_cents+case when version.include_regular_commission then service+product+designated else 0 end)/version.hourly_divisor::numeric when profile.pay_basis='hourly' then profile.base_pay_cents::numeric else 0 end;
  select coalesce(round(sum(overtime_hourly*greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint,0) into overtime
  from (select work_date,overtime_type,sum(minutes)::int minutes from public.spa_overtime_entries where staff_id=(row->>'staff_id')::uuid and work_date between p_from and p_to and status='approved' group by work_date,overtime_type)o
  join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=row->>'employment_type_code' and r.overtime_type=o.overtime_type and o.minutes>r.start_minute;
  select coalesce(sum(case when coalesce(profile.pay_basis,'session')='session' then o.minutes else greatest(0,o.minutes-coalesce((select sum(greatest(0,least(o.minutes,r.end_minute)-r.start_minute)) from public.spa_payroll_overtime_rates r where r.rule_version_id=version.id and r.employment_type_code=row->>'employment_type_code' and r.overtime_type=o.overtime_type and o.minutes>r.start_minute),0)) end),0)::bigint into unpriced
  from (select work_date,overtime_type,sum(minutes)::int minutes from public.spa_overtime_entries where staff_id=(row->>'staff_id')::uuid and work_date between p_from and p_to and status='approved' group by work_date,overtime_type)o;
  total:=base+service+product+designated+overtime+coalesce((row->>'bonus_cents')::bigint,0)+coalesce((row->>'allowance_cents')::bigint,0)-coalesce((row->>'deduction_cents')::bigint,0);
  result:=result||jsonb_build_array(row||jsonb_build_object('work_category',title.work_category,'job_title_code',title.code,'classification_pending',title.legacy,'contract_started_on',contract_start,'contract_start_pending',contract_pending,
   'pay_basis',profile.pay_basis,'base_pay_rate_cents',profile.base_pay_cents,'commission_bps',profile.service_commission_bps,'service_commission_bps',profile.service_commission_bps,
   'product_commission_bps',profile.product_commission_bps,'designated_bonus_bps',profile.designated_client_bonus_bps,'self_sourced_commission_bps',profile.self_sourced_commission_bps,
   'minimum_attendance_minutes',profile.minimum_attendance_minutes,'minimum_service_minutes',profile.minimum_service_minutes,'commission_start_service_minutes',profile.commission_start_service_minutes,
   'service_commission_mode',profile.service_commission_mode,'contractor_count_scope',profile.contractor_count_scope,'service_policy_status',profile.service_policy_status,
   'compensation_configured',configured,'commission_policy_ready',ready,'commission_eligibility_met',eligibility,'qualification_work_minutes',qualification_work,'qualification_service_minutes',qualification_service,
   'monthly_eligibility_work_minutes',qualification_work,'monthly_eligibility_service_minutes',qualification_service,
   'base_cents',base,'service_commission_cents',service,'product_commission_cents',product,'designated_bonus_cents',designated,'overtime_cents',overtime,'total_cents',greatest(0,total),'designated_clients',designated_count,'designated_service_sales_cents',designated_sales,
   'unpriced_overtime_minutes',unpriced,'commission_warning',warning,'overtime_warning',case when unpriced>0 then '加班分鐘未完整設定倍率或時薪' else row->>'overtime_warning' end,
   'calculation',(row->'calculation')||jsonb_build_object('calculation_engine','ordered_v2','profile_source','rule_version_snapshot','tier_mode',case when title.legacy then 'legacy_preview_pending_mapping' else 'chronological_per_service' end,
    'tier_reset','calendar_month','contractor_count_scope',profile.contractor_count_scope,'product_commission_basis','sale_percentage_snapshot','self_sourced_basis','explicit_settlement_snapshot',
    'component_total_before_floor_cents',total)));
 end loop;
 return result;
end $$;

create or replace function public.spa_payroll_run_save(p_from date,p_to date,p_rule uuid,p_finalize boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions; preview jsonb;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726005); perform pg_advisory_xact_lock(726099);
 if p_finalize is null then raise exception 'INVALID_INPUT'; end if;
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 if p_finalize and version.calculation_engine='ordered_v2' then
  if p_from<>date_trunc('month',p_from::timestamp)::date or p_to<>(date_trunc('month',p_from::timestamp)+interval '1 month'-interval '1 day')::date then raise exception 'PAYROLL_FULL_MONTH_REQUIRED'; end if;
  preview:=spa_private.payroll_preview(p_from,p_to,version.id);
  if exists(select 1 from jsonb_array_elements(preview)x where coalesce((x->>'classification_pending')::boolean,false)) then raise exception 'PAYROLL_CLASSIFICATION_REQUIRED'; end if;
  if exists(select 1 from jsonb_array_elements(preview)x where coalesce((x->>'contract_start_pending')::boolean,false)) then raise exception 'CONTRACT_COOPERATION_DATE_REQUIRED'; end if;
  if exists(select 1 from jsonb_array_elements(preview)x where not coalesce((x->>'commission_policy_ready')::boolean,false) and coalesce((x->>'compensation_configured')::boolean,false)) then raise exception 'PAYROLL_POLICY_CONFIRMATION_REQUIRED'; end if;
 end if;
 return spa_private.payroll_run_save_legacy_20261010(p_from,p_to,version.id,p_finalize);
end $$;

alter function spa_private.payroll_rule_reference(uuid,jsonb) rename to payroll_rule_reference_before_cooperation_20261010;
create or replace function spa_private.payroll_rule_reference(p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.payroll_rule_reference_before_cooperation_20261010(p_rule,p_wage);
begin
 return result||jsonb_build_object('profile',(result->'profile')||jsonb_build_object('contract_started_on',p_wage->'contract_started_on','contract_start_pending',p_wage->'contract_start_pending'));
end $$;

alter function spa_private.payroll_source_packet(uuid,date,date,uuid,jsonb) rename to payroll_source_packet_before_cooperation_20261010;
create or replace function spa_private.payroll_source_packet(p_staff uuid,p_from date,p_to date,p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.payroll_source_packet_before_cooperation_20261010(p_staff,p_from,p_to,p_rule,p_wage); start_date date:=nullif(p_wage->>'contract_started_on','')::date; prior jsonb; count_before bigint;
begin
 if p_wage->'calculation'->>'calculation_engine'='ordered_v2' and p_wage->>'employment_type_code'='contractor' then
  select coalesce(jsonb_agg(to_jsonb(q) order by event_time,source_kind,source_id),'[]'),coalesce(sum(quantity),0) into prior,count_before from (
   select 'appointment'::text source_kind,a.id source_id,a.reference,a.business_date date,a.starts_at event_time,1 quantity
    from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null
    where a.staff_id=p_staff and a.status='completed' and a.business_date>=start_date and a.business_date<p_from
     and (p_wage->>'contractor_count_scope'='lifetime' or a.business_date>=date_trunc('month',p_from::timestamp)::date)
   union all
   select 'pos_service',i.id,o.reference,(o.paid_at at time zone 'Asia/Taipei')::date,o.paid_at,i.quantity
    from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
    where i.staff_id=p_staff and i.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date>=start_date and (o.paid_at at time zone 'Asia/Taipei')::date<p_from
     and (p_wage->>'contractor_count_scope'='lifetime' or (o.paid_at at time zone 'Asia/Taipei')::date>=date_trunc('month',p_from::timestamp)::date)
  )q;
  result:=jsonb_set(result,'{sources,commission_context}',jsonb_build_object('contract_started_on',start_date,'contractor_count_scope',p_wage->'contractor_count_scope','prior_service_count',count_before,'prior_service_references',prior),true);
 end if;
 return result;
end $$;

revoke all on function spa_private.staff_cooperation_dates_guard(),spa_private.staff_profile_save_before_cooperation_20261010(jsonb),spa_private.payroll_rule_reference_before_cooperation_20261010(uuid,jsonb),spa_private.payroll_source_packet_before_cooperation_20261010(uuid,date,date,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.spa_staff_profile_save_v2(jsonb) from public,anon,authenticated;
grant execute on function public.spa_staff_profile_save_v2(jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
