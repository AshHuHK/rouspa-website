begin;

-- One monthly base for category 02. NULL identifies an older historical policy
-- that still needs its original per-rank wage table for reference.
alter table spa_private.payroll_notices add column monthly_base_cents bigint
 check(monthly_base_cents between 0 and 100000000);

-- Apply the owner-authorized correction to editable/current notice versions
-- only. A saved finalized wage packet is never rewritten by this migration.
do $$
begin
 if exists(select 1 from public.spa_payroll_rule_versions v
  where v.calculation_engine='notice_v1' and v.status in ('active','draft') and exists(
   select 1 from public.spa_payroll_runs r where r.rule_version_id=v.id and r.status='finalized'))
 then raise exception 'PAYROLL_FLAT_BASE_REQUIRES_NEW_VERSION'; end if;
end $$;
update spa_private.payroll_notices n set monthly_base_cents=2520000
 from public.spa_payroll_rule_versions v where v.id=n.rule_id and v.status in ('active','draft');
update spa_private.payroll_notice_ranks r set monthly_base_cents=n.monthly_base_cents
 from spa_private.payroll_notices n where n.rule_id=r.rule_id and n.monthly_base_cents is not null;
update public.spa_payroll_runs r set needs_recalculation=true
 where r.status='draft' and exists(select 1 from spa_private.payroll_notices n where n.rule_id=r.rule_version_id and n.monthly_base_cents is not null);

alter function public.spa_payroll_notice_setup(date) rename to payroll_notice_setup_before_flat_monthly;
alter function public.payroll_notice_setup_before_flat_monthly(date) set schema spa_private;
revoke all on function spa_private.payroll_notice_setup_before_flat_monthly(date) from public,anon,authenticated;
create function public.spa_payroll_notice_setup(p_effective date) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid; amount bigint;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 select n.monthly_base_cents into amount from spa_private.payroll_notices n
 join public.spa_payroll_rule_versions v on v.id=n.rule_id where v.status='active'
 order by v.effective_from desc,v.version_no desc limit 1;
 result:=spa_private.payroll_notice_setup_before_flat_monthly(p_effective);
 update spa_private.payroll_notices set monthly_base_cents=coalesce(amount,2520000) where rule_id=result;
 update spa_private.payroll_notice_ranks set monthly_base_cents=coalesce(amount,2520000) where rule_id=result;
 return result;
end $$;

alter function public.spa_payroll_notice_save(uuid,jsonb,jsonb) rename to payroll_notice_save_before_flat_monthly;
alter function public.payroll_notice_save_before_flat_monthly(uuid,jsonb,jsonb) set schema spa_private;
revoke all on function spa_private.payroll_notice_save_before_flat_monthly(uuid,jsonb,jsonb) from public,anon,authenticated;
create function public.spa_payroll_notice_save(p_rule uuid,p_settings jsonb,p_ranks jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare amount bigint;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 select coalesce(nullif(p_settings->>'monthly_base_cents','')::bigint,n.monthly_base_cents,2520000)
 into amount from spa_private.payroll_notices n where n.rule_id=p_rule;
 if amount is null or amount not between 0 and 100000000 then raise exception 'INVALID_INPUT'; end if;
 if jsonb_typeof(p_ranks) is distinct from 'array' then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from jsonb_array_elements(p_ranks) r where (r->>'monthly_base_cents')::bigint is distinct from amount)
 then raise exception 'PAYROLL_MONTHLY_BASE_MISMATCH'; end if;
 perform spa_private.payroll_notice_save_before_flat_monthly(p_rule,p_settings,p_ranks);
 update spa_private.payroll_notices set monthly_base_cents=amount where rule_id=p_rule;
end $$;

create or replace function spa_private.payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v public.spa_payroll_rule_versions; n spa_private.payroll_notices; assignment spa_private.payroll_notice_staff; rank spa_private.payroll_notice_ranks; passed_rank spa_private.payroll_notice_ranks;
 row jsonb; lines jsonb; sales jsonb; result jsonb:='[]'; person uuid; base_rate bigint; basis text; title text; employment text;
 service bigint; designated bigint; product bigint; product_rate int; voucher bigint; product_return bigint; entered_bonus bigint; base bigint; total bigint;
 work bigint; overtime bigint; unpriced bigint; overtime_hourly numeric; minutes bigint; ordinary_minutes bigint; income bigint; designated_income bigint; designated_count bigint;
 pending boolean; pre_contract boolean; ready boolean; cutover_attention boolean; warning text; start_rate int; threshold int; overtime_key text; usual_rows jsonb;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select * into v from public.spa_payroll_rule_versions where id=coalesce(p_rule,spa_private.payroll_notice_rule_on(p_to));
 if v.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 if v.calculation_engine<>'notice_v1' then return spa_private.payroll_preview_before_notice(p_from,p_to,v.id); end if;
 -- Pay-rate and overtime formulas belong to one natural month.
 if p_to<v.effective_from or date_trunc('month',p_from::timestamp)<>date_trunc('month',p_to::timestamp) then return '[]'; end if;
 cutover_attention:=p_from<v.effective_from and spa_private.payroll_notice_has_earlier_activity(v.effective_from);
 select * into n from spa_private.payroll_notices where rule_id=v.id;
 usual_rows:=spa_private.payroll_preview_before_notice(p_from,p_to,v.id);
 for row in
  select value from jsonb_array_elements(usual_rows)
  union all
  select spa_private.payroll_source_totals(spa_private.payroll_source_records(s.id,p_from,p_to))
   ||jsonb_build_object('staff_id',s.id,'employee',s.name,'job_title_id',s.job_title_id,
    'employment_status',s.employment_status,'departed_on',s.departed_on,'sales_only',true,
    'calculation',jsonb_build_object('rule_version',v.version_no,'total_floor_zero',true))
  from public.spa_staff s join spa_private.payroll_notice_staff a on a.staff_id=s.id and a.rule_id=v.id
  where not exists(select 1 from jsonb_array_elements(usual_rows)x where x->>'staff_id'=s.id::text)
   and (
    exists(select 1 from spa_private.payroll_notice_returns r where r.staff_id=s.id and r.payroll_date between p_from and p_to)
    or exists(select 1 from public.spa_packages p where p.payroll_seller_id=s.id and p.payroll_sale_bonus_cents>0
     and (p.created_at at time zone 'Asia/Taipei')::date between p_from and p_to)
   )
 loop
  person:=(row->>'staff_id')::uuid;
  sales:=spa_private.payroll_notice_sales(person,p_from,p_to);
  select coalesce(sum((x->>'commission_cents')::bigint) filter(where x->>'kind' in ('package_sale','package_return')),0),
   coalesce(sum((x->>'commission_cents')::bigint) filter(where x->>'kind'='product_return'),0)
  into voucher,product_return from jsonb_array_elements(sales)x;
  entered_bonus:=coalesce((row->>'bonus_cents')::bigint,0);
  select * into assignment from spa_private.payroll_notice_staff where rule_id=v.id and staff_id=person;
  if not found and not exists(select 1 from public.spa_job_titles where id=(row->>'job_title_id')::uuid and work_category='technician') then
   -- Use the copied prior configuration for people outside the four technician categories.
   row:=row||jsonb_build_object('bonus_cents',entered_bonus+voucher,'package_bonus_cents',voucher,'entered_bonus_cents',entered_bonus,
    'total_cents',greatest(0,coalesce((row->'calculation'->>'component_total_before_floor_cents')::bigint,(row->>'total_cents')::bigint)+voucher));
   result:=result||jsonb_build_array(row);
   continue;
  end if;
  select * into rank from spa_private.payroll_notice_ranks where rule_id=v.id and rank_no=assignment.rank_no;
  select * into passed_rank from spa_private.payroll_notice_ranks where rule_id=v.id and rank_no=assignment.passed_rank_no;
  pending:=assignment.category is null;
  lines:=spa_private.payroll_notice_lines(person,p_from,p_to,v.id);
  select coalesce(sum((x->>'service_commission_cents')::bigint),0),coalesce(sum((x->>'designated_bonus_cents')::bigint),0),
   coalesce(sum((x->>'duration_minutes')::int),0),coalesce(sum((x->>'net_cents')::bigint),0),
   coalesce(sum((x->>'net_cents')::bigint) filter(where (x->>'designated')::boolean),0),
   count(*) filter(where (x->>'designated')::boolean),coalesce(bool_or((x->>'pre_contract')::boolean),false),
   coalesce(sum((x->>'ordinary_qualified_minutes')::int),0)
  into service,designated,minutes,income,designated_income,designated_count,pre_contract,ordinary_minutes from jsonb_array_elements(lines)x;
  pre_contract:=pre_contract or (assignment.category='04' and exists(select 1 from public.spa_time_entries e
   where e.staff_id=person and e.status='approved' and e.work_date between p_from and p_to and e.work_date<assignment.contract_from));
  pre_contract:=coalesce(pre_contract,false);
  designated:=designated+coalesce((row->>'manual_designated_bonus_cents')::bigint,0);
  base_rate:=case assignment.category when '01' then 3100000 when '02' then coalesce(n.monthly_base_cents,rank.monthly_base_cents) when '03' then 20500 else 0 end;
  if assignment.category='02' and assignment.passed_on<=date_trunc('month',p_from::timestamp)::date then base_rate:=coalesce(n.monthly_base_cents,passed_rank.monthly_base_cents); end if;
  basis:=case when assignment.category in ('01','02') then 'monthly' when assignment.category='03' then 'hourly' else 'session' end;
  title:=case assignment.category when '01' then '正職技師' when '02' then '兼職技師（月薪）' when '03' then '兼職技師（時薪）' when '04' then '承攬技師' else '待設定薪資類別' end;
  employment:=case assignment.category when '01' then 'full_time' when '02' then 'part_time' when '03' then 'part_time' when '04' then 'contractor' else row->>'employment_type_code' end;
  start_rate:=case assignment.category when '01' then coalesce(assignment.start_bps,rank.full_time_start_bps) when '02' then coalesce(assignment.start_bps,rank.monthly_start_bps) when '03' then 500 when '04' then 3000 end;
  if assignment.passed_on<=p_to then
   start_rate:=case assignment.category when '01' then passed_rank.full_time_start_bps when '02' then passed_rank.monthly_start_bps else start_rate end;
  end if;
  threshold:=case assignment.category when '01' then n.full_time_threshold_minutes when '02' then n.monthly_threshold_minutes when '03' then n.hourly_threshold_minutes else 0 end;
  work:=(row->>'work_minutes')::bigint;
  base:=case when coalesce((row->>'sales_only')::boolean,false) then 0
   when basis='monthly' then base_rate when basis='hourly' then round(base_rate*work/60.0)::bigint else 0 end;
  product_rate:=500;
  select coalesce(sum(round(i.net_total_cents*product_rate/10000.0)::bigint),0)
  into product from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
  where i.staff_id=person and i.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between greatest(p_from,v.effective_from) and p_to;
  product:=product+product_return;
  overtime_key:=employment;
  overtime_hourly:=case basis when 'monthly' then (base_rate+case when v.include_regular_commission then service+product+designated else 0 end)/v.hourly_divisor::numeric
   when 'hourly' then base_rate else 0 end;
  select coalesce(round(sum(overtime_hourly*allocated.weighted_minutes/600000.0))::bigint,0),
   coalesce(sum(case when basis='session' then o.minutes else greatest(0,o.minutes-allocated.covered_minutes) end),0)
  into overtime,unpriced
  from (select o.work_date,o.overtime_type,sum(o.minutes)::int minutes from public.spa_overtime_entries o
   where o.staff_id=person and o.status='approved' and o.work_date between p_from and p_to group by o.work_date,o.overtime_type)o
  cross join lateral (
   select coalesce(sum(greatest(0,least(o.minutes,r.end_minute)-r.start_minute)*r.multiplier_bps),0) weighted_minutes,
    coalesce(sum(greatest(0,least(o.minutes,r.end_minute)-r.start_minute)),0) covered_minutes
   from public.spa_payroll_overtime_rates r where r.rule_version_id=v.id and r.employment_type_code=overtime_key and r.overtime_type=o.overtime_type
  )allocated;
  total:=base+service+designated+product+overtime+entered_bonus+voucher+coalesce((row->>'allowance_cents')::bigint,0)-coalesce((row->>'deduction_cents')::bigint,0);
  ready:=not pending and not pre_contract and not cutover_attention;
  warning:=case when pending then '請設定這位技師的薪資類別' when pre_contract then '本期包含承攬開始前的服務或出勤，請先核對原聘僱期間'
   when cutover_attention then '本月補登了啟用日前的紀錄，請先核對切換月薪資'
   when total<0 and (voucher<0 or product_return<0) then '本期報酬不足扣回退款抽成，請核對差額'
   else '' end;
  result:=result||jsonb_build_array(row||jsonb_build_object(
   'role',title,'employment_type',title,'employment_type_code',employment,'work_category','technician',
   'notice_category',assignment.category,'notice_rank',case when assignment.passed_on<=p_to then assignment.passed_rank_no else assignment.rank_no end,'classification_pending',pending,
   'contract_started_on',assignment.contract_from,'contract_start_pending',pre_contract,
   'pay_basis',basis,'base_pay_rate_cents',base_rate,'commission_bps',coalesce(start_rate,0),'service_commission_bps',start_rate,
   'product_commission_bps',product_rate,'designated_bonus_bps',500,'minimum_attendance_minutes',0,
   'minimum_service_minutes',threshold,'commission_start_service_minutes',threshold,
   'compensation_configured',not pending,'commission_policy_ready',ready,'commission_eligibility_met',ready,
   'commission_warning',warning,'service_minutes',case when pending then (row->>'service_minutes')::bigint else minutes end,
   'ordinary_qualified_minutes',ordinary_minutes,
   'service_sales_cents',case when pending then (row->>'service_sales_cents')::bigint else income end,
   'designated_clients',designated_count,'designated_service_sales_cents',designated_income,
   'base_cents',base,'service_commission_cents',service,'designated_bonus_cents',designated,'product_commission_cents',product,
   'package_bonus_cents',voucher,'product_return_cents',product_return,'entered_bonus_cents',entered_bonus,'bonus_cents',entered_bonus+voucher,
   'overtime_cents',overtime,'unpriced_overtime_minutes',unpriced,'overtime_warning',case when unpriced>0 then '請核對未定價的加班分鐘' else row->>'overtime_warning' end,
   'total_cents',greatest(0,total),'calculation',(row->'calculation')||jsonb_build_object(
    'calculation_engine','notice_v1','component_total_before_floor_cents',total,'step_minutes',n.step_minutes,'threshold_minutes',threshold,
    'probation_passed_on',assignment.passed_on,'contract_credited_from',assignment.credited_from,
    'contract_anniversary',case when assignment.category='04' then (coalesce(assignment.credited_from,assignment.contract_from)+interval '6 months')::date end
   )));
 end loop;
 return result;
end $$;

-- Schedule reminders follow the same explicit HR category immediately,
-- including a monthly part-time rank with no old shared compensation profile.
create or replace function spa_private.staff_schedule_role(p_staff uuid) returns text
language sql stable security definer set search_path='' as $$
 select case when j.work_category='owner' then null
  when j.work_category='technician' and coalesce(s.payroll_category_code,a.category)='01' then 'full_time'
  when j.work_category='technician' and coalesce(s.payroll_category_code,a.category)='02' then 'part_time_monthly'
  when j.work_category='technician' and coalesce(s.payroll_category_code,a.category)='03' then 'part_time_hourly'
  when j.work_category='technician' and coalesce(s.payroll_category_code,a.category)='04' then 'contractor'
  when s.employment_type_code='contractor' then 'contractor'
  when s.employment_type_code='full_time' then 'full_time'
  when s.employment_type_code='part_time' then case when coalesce(c.pay_basis,s.pay_basis)='monthly' then 'part_time_monthly' else 'part_time_hourly' end
 end
 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
 left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code
 left join spa_private.payroll_notice_staff a on a.staff_id=s.id and a.rule_id=spa_private.payroll_notice_rule_on((now() at time zone 'Asia/Taipei')::date)
 where s.id=p_staff
$$;
revoke all on function public.spa_payroll_notice_setup(date),public.spa_payroll_notice_save(uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.spa_payroll_notice_setup(date),public.spa_payroll_notice_save(uuid,jsonb,jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
