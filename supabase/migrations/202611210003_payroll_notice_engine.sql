begin;

create function spa_private.payroll_notice_lines(p_staff uuid,p_from date,p_to date,p_rule uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with policy as (
  select n.*,s.category,s.contract_from,s.credited_from,s.passed_on,v.effective_from,
   case s.category when '01' then n.full_time_threshold_minutes when '02' then n.monthly_threshold_minutes else n.hourly_threshold_minutes end threshold,
   case s.category when '01' then coalesce(s.start_bps,r.full_time_start_bps) when '02' then coalesce(s.start_bps,r.monthly_start_bps) else 500 end start_bps,
   case s.category when '01' then passed.full_time_start_bps when '02' then passed.monthly_start_bps end passed_start_bps,
   case when s.category='02' then 2500 else 3000 end cap_bps
  from spa_private.payroll_notices n join spa_private.payroll_notice_staff s on s.rule_id=n.rule_id
  join public.spa_payroll_rule_versions v on v.id=n.rule_id
  left join spa_private.payroll_notice_ranks r on r.rule_id=s.rule_id and r.rank_no=s.rank_no
  left join spa_private.payroll_notice_ranks passed on passed.rule_id=s.rule_id and passed.rank_no=s.passed_rank_no
  where n.rule_id=p_rule and s.staff_id=p_staff
 ), units as (
  select 'appointment'::text source_kind,a.id source_id,a.reference,a.business_date date,a.starts_at event_time,
   a.id order_key,0 line_position,1 unit_index,1 quantity,coalesce(m.minutes,a.duration_minutes_snapshot) duration_minutes,m.minutes is not null actual_minutes_recorded,
   case when pkg.id is null then greatest(0,c.revenue_cents-a.tea_cents)
    else (floor((pkg.paid_cents-pkg.payroll_sale_bonus_cents)*redemption.position::numeric/pkg.sessions)
     -floor((pkg.paid_cents-pkg.payroll_sale_bonus_cents)*(redemption.position-1)::numeric/pkg.sessions))::bigint end net_cents,
   c.designated_client_snapshot designated,c.self_sourced_client_snapshot self_sourced,
   pkg.id package_id,pkg.paid_cents package_paid_cents,pkg.payroll_sale_bonus_cents package_sale_bonus_cents,pkg.sessions package_sessions
  from public.spa_appointments a join public.spa_checkouts c on c.appointment_id=a.id and c.refunded_at is null
  left join public.spa_packages pkg on pkg.id=c.package_id
  left join lateral (
   select count(*) position from public.spa_checkouts other where other.package_id=pkg.id
    and other.refunded_at is null and (other.created_at,other.id)<=(c.created_at,c.id)
  )redemption on pkg.id is not null
  left join spa_private.payroll_notice_minutes m on m.source_kind='appointment' and m.source_id=a.id
  where a.staff_id=p_staff and a.status='completed' and a.business_date between date_trunc('month',p_from::timestamp)::date and p_to
  union all
  select 'pos_service',i.id,o.reference,(o.paid_at at time zone 'Asia/Taipei')::date,o.paid_at,o.id,i.line_position,k,1,
   case when m.minutes is null then i.duration_minutes_snapshot else (m.minutes*k/i.quantity)-(m.minutes*(k-1)/i.quantity) end,
   m.minutes is not null,
   (floor(i.net_total_cents*k::numeric/i.quantity)-floor(i.net_total_cents*(k-1)::numeric/i.quantity))::bigint,
   i.designated_client_snapshot,i.self_sourced_client_snapshot,null,null,null,null
  from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
  left join spa_private.payroll_notice_minutes m on m.source_kind='pos_service' and m.source_id=i.id
  cross join lateral generate_series(1,i.quantity) k
  where i.staff_id=p_staff and i.item_type='service' and o.status='paid'
   and (o.paid_at at time zone 'Asia/Taipei')::date between date_trunc('month',p_from::timestamp)::date and p_to
 ), qualified as (
  select u.*,case when p.category='04' then 0 when u.date>=p.passed_on then coalesce(p.passed_start_bps,p.start_bps) else p.start_bps end ordinary_start_bps,
   p.category,p.contract_from,p.credited_from,p.threshold,p.step_minutes,p.cap_bps
  from units u cross join policy p where u.date>=p.effective_from
 ), chronological as (
  select u.*,
   coalesce(sum(duration_minutes) filter (where ordinary_start_bps>0) over monthly,0)::bigint before_minutes,
   case when ordinary_start_bps>0 then duration_minutes else 0 end ordinary_qualified_minutes
  from qualified u
  window monthly as (partition by date_trunc('month',date::timestamp)
   order by event_time,source_kind,order_key,line_position,unit_index rows between unbounded preceding and 1 preceding)
 ), amounts as (
  select c.*,
   c.designated or (c.category='04' and c.self_sourced) actual_designated,
   c.category='04' and c.date<c.contract_from pre_contract,
   case when c.category='04' then (coalesce(c.credited_from,c.contract_from)+interval '6 months')::date end contract_anniversary,
   case when c.category='04' then
    case when c.date<c.contract_from then 0 when c.date<(coalesce(c.credited_from,c.contract_from)+interval '6 months')::date then 3000 else 4000 end
   end contractor_bps,
   seg.amount progressive_amount,seg.segments progressive_segments
  from chronological c
  left join lateral (
   select coalesce(sum(s.commission_cents),0)::bigint amount,coalesce(jsonb_agg(jsonb_build_object(
    'basis',s.stage,'metric','service_minutes','from',s.from_minute,'to',s.to_minute,
    'net_cents',s.net_cents,'rate_bps',s.rate_bps,'commission_cents',s.commission_cents) order by s.from_minute),'[]') segments
   from spa_private.payroll_notice_segments(c.before_minutes,c.duration_minutes,c.net_cents,c.threshold,c.step_minutes,
    c.ordinary_start_bps,c.cap_bps,false) s
  )seg on c.category<>'04' and c.ordinary_start_bps>0
  where c.date between p_from and p_to
 )
 select coalesce(jsonb_agg((to_jsonb(a)-array['order_key','line_position','before_minutes','progressive_amount','progressive_segments','actual_designated','contract_from','credited_from','threshold','step_minutes','cap_bps'])
  ||jsonb_build_object(
   'designated',a.actual_designated,'metric','service_minutes','metric_from',a.before_minutes,'metric_to',a.before_minutes+a.ordinary_qualified_minutes,
   'service_minutes_from',a.before_minutes,'service_minutes_to',a.before_minutes+a.ordinary_qualified_minutes,'eligible',not a.pre_contract,
   'service_commission_cents',case when a.category='04' then round(a.net_cents*a.contractor_bps/10000.0)::bigint else coalesce(a.progressive_amount,0) end,
   'designated_bonus_cents',case when a.actual_designated and not a.pre_contract then round(a.net_cents*0.05)::bigint else 0 end,
   'commission_segments',case when a.category='04' then jsonb_build_array(jsonb_build_object('basis','contract_anniversary',
    'net_cents',a.net_cents,'rate_bps',a.contractor_bps,'commission_cents',round(a.net_cents*a.contractor_bps/10000.0)::bigint))
    when a.ordinary_start_bps=0 then jsonb_build_array(jsonb_build_object('basis','probation','net_cents',a.net_cents,'rate_bps',0,'commission_cents',0))
    else a.progressive_segments end
  ) order by a.event_time,a.source_kind,a.order_key,a.line_position,a.unit_index),'[]')
 from amounts a;
$$;

create function spa_private.payroll_notice_has_earlier_activity(p_cutover date) returns boolean
language sql stable security definer set search_path='' as $$
 with bounds as (select date_trunc('month',p_cutover::timestamp)::date first_day)
 select date_part('day',p_cutover)>1 and (
  exists(select 1 from public.spa_appointments a,bounds b where a.status='completed' and a.business_date>=b.first_day and a.business_date<p_cutover)
  or exists(select 1 from public.spa_orders o,bounds b where o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date>=b.first_day and (o.paid_at at time zone 'Asia/Taipei')::date<p_cutover)
  or exists(select 1 from public.spa_packages p,bounds b where (p.created_at at time zone 'Asia/Taipei')::date>=b.first_day and (p.created_at at time zone 'Asia/Taipei')::date<p_cutover)
  or exists(select 1 from public.spa_time_entries t,bounds b where t.status='approved' and t.work_date>=b.first_day and t.work_date<p_cutover)
  or exists(select 1 from public.spa_overtime_entries t,bounds b where t.status='approved' and t.work_date>=b.first_day and t.work_date<p_cutover)
 );
$$;

-- Keep earlier versions callable with their existing rules and calculated fields.
alter function spa_private.payroll_preview(date,date,uuid) rename to payroll_preview_before_notice;
create function spa_private.payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
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
  base_rate:=case assignment.category when '01' then 3100000 when '02' then rank.monthly_base_cents when '03' then 20500 else 0 end;
  if assignment.category='02' and assignment.passed_on<=date_trunc('month',p_from::timestamp)::date then base_rate:=passed_rank.monthly_base_cents; end if;
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

alter function spa_private.payroll_source_packet(uuid,date,date,uuid,jsonb) rename to payroll_source_packet_before_notice;
create function spa_private.payroll_source_packet(p_staff uuid,p_from date,p_to date,p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare packet jsonb:=spa_private.payroll_source_packet_before_notice(p_staff,p_from,p_to,p_rule,p_wage);
 lines jsonb; sales jsonb; totals jsonb; refs jsonb; products jsonb; rate int; source_key text;
begin
 if not exists(select 1 from spa_private.payroll_notices where rule_id=p_rule) then return packet; end if;
 sales:=spa_private.payroll_notice_sales(p_staff,p_from,p_to);
 packet:=jsonb_set(packet,'{sources,notice_sales}',sales,true);
 if p_wage->>'notice_category' is null then return packet; end if;
 lines:=spa_private.payroll_notice_lines(p_staff,p_from,p_to,p_rule);
 foreach source_key in array array['services','pos_services'] loop
  packet:=jsonb_set(packet,array['sources',source_key],coalesce((
   select jsonb_agg(row.value||case when fact.source_id is null then '{}'::jsonb else jsonb_build_object(
    'notice_minutes',fact.minutes,'duration_minutes',fact.minutes/(row.value->>'quantity')::int,'net_cents',fact.net_cents,'designated',fact.designated) end order by row.ordinality)
   from jsonb_array_elements(packet->'sources'->source_key) with ordinality row
   left join lateral (
    select x->>'source_id' source_id,sum((x->>'duration_minutes')::int) minutes,sum((x->>'net_cents')::bigint) net_cents,
     bool_or((x->>'designated')::boolean) designated
    from jsonb_array_elements(lines)x where x->>'source_id'=row.value->>'id'
     and x->>'source_kind'=case source_key when 'services' then 'appointment' else 'pos_service' end
    group by x->>'source_id'
   )fact on true
  ),'[]'),true);
 end loop;
 rate:=(p_wage->>'product_commission_bps')::int;
 select coalesce(jsonb_agg(x||jsonb_build_object('snapshot_commission_cents',case when rate is null then (x->>'snapshot_commission_cents')::bigint
  else round((x->>'net_cents')::bigint*rate/10000.0)::bigint end,'commission_bps_snapshot',coalesce(rate,(x->>'commission_bps_snapshot')::int))),'[]')
 into products from jsonb_array_elements(packet->'sources'->'products')x;
 packet:=jsonb_set(jsonb_set(packet,'{sources,commission_details}',lines,true),'{sources,products}',products,true);
 totals:=(packet->'source_totals')||jsonb_build_object(
  'service_minutes',coalesce((select sum((x->>'duration_minutes')::int) from jsonb_array_elements(lines)x),0),
  'ordinary_qualified_minutes',coalesce((select sum((x->>'ordinary_qualified_minutes')::int) from jsonb_array_elements(lines)x),0),
  'service_sales_cents',coalesce((select sum((x->>'net_cents')::bigint) from jsonb_array_elements(lines)x),0),
  'designated_clients',(select count(*) from jsonb_array_elements(lines)x where (x->>'designated')::boolean),
  'designated_service_sales_cents',coalesce((select sum((x->>'net_cents')::bigint) from jsonb_array_elements(lines)x where (x->>'designated')::boolean),0),
  'service_commission_cents',coalesce((select sum((x->>'service_commission_cents')::bigint) from jsonb_array_elements(lines)x),0),
  'designated_bonus_cents',coalesce((select sum((x->>'designated_bonus_cents')::bigint) from jsonb_array_elements(lines)x),0)+coalesce((p_wage->>'manual_designated_bonus_cents')::bigint,0),
  'product_commission_cents',coalesce((select sum((x->>'snapshot_commission_cents')::bigint) from jsonb_array_elements(products)x),0)
   +coalesce((select sum((x->>'commission_cents')::bigint) from jsonb_array_elements(sales)x where x->>'kind'='product_return'),0),
  'package_bonus_cents',coalesce((select sum((x->>'commission_cents')::bigint) from jsonb_array_elements(sales)x where x->>'kind' in ('package_sale','package_return')),0)
 );
 totals:=totals||jsonb_build_object('bonus_cents',coalesce((totals->>'bonus_cents')::bigint,0)+(totals->>'package_bonus_cents')::bigint);
 refs:=(packet->'rule_reference')||jsonb_build_object('notice',p_wage->'calculation','tiers','[]'::jsonb,
  'rates',coalesce((select jsonb_agg(to_jsonb(r) order by r.overtime_type,r.start_minute) from public.spa_payroll_overtime_rates r
   where r.rule_version_id=p_rule and r.employment_type_code=p_wage->>'employment_type_code'),'[]'));
 return packet||jsonb_build_object('source_totals',totals,'rule_reference',refs,'schema_version',3);
end $$;

alter function public.spa_payroll_run_save(date,date,uuid,boolean) set schema spa_private;
alter function spa_private.spa_payroll_run_save(date,date,uuid,boolean) rename to payroll_run_save_before_notice;
create function public.spa_payroll_run_save(p_from date,p_to date,p_rule uuid,p_finalize boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare v public.spa_payroll_rule_versions; wage jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726005);
 perform pg_advisory_xact_lock(726099);
 select * into v from public.spa_payroll_rule_versions where id=coalesce(p_rule,spa_private.payroll_notice_rule_on(p_to));
 if v.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 if v.calculation_engine='notice_v1' then
  if p_to<v.effective_from or date_trunc('month',p_from::timestamp)<>date_trunc('month',p_to::timestamp)
  then raise exception 'PAYROLL_FULL_MONTH_REQUIRED'; end if;
  if p_finalize then
   if v.status<>'active' or v.id is distinct from spa_private.payroll_notice_rule_on(p_to) then raise exception 'PAYROLL_NOTICE_NOT_ACTIVE'; end if;
   if p_from<>date_trunc('month',p_from::timestamp)::date or p_to<>(date_trunc('month',p_from::timestamp)+interval '1 month'-interval '1 day')::date
   then raise exception 'PAYROLL_FULL_MONTH_REQUIRED'; end if;
   if p_from<v.effective_from and spa_private.payroll_notice_has_earlier_activity(v.effective_from)
   then raise exception 'PAYROLL_NOTICE_CUTOVER_ACTIVITY'; end if;
   wage:=spa_private.payroll_preview(p_from,p_to,v.id);
   if exists(select 1 from jsonb_array_elements(wage)x where coalesce((x->>'classification_pending')::boolean,false))
   then raise exception 'PAYROLL_CLASSIFICATION_REQUIRED'; end if;
   if exists(select 1 from jsonb_array_elements(wage)x where x->>'work_category'='technician' and not coalesce((x->>'commission_policy_ready')::boolean,false))
   then raise exception 'PAYROLL_POLICY_CONFIRMATION_REQUIRED'; end if;
  end if;
 elsif p_finalize and exists(select 1 from spa_private.payroll_notices where rule_id=spa_private.payroll_notice_rule_on(p_to))
 then raise exception 'PAYROLL_NOTICE_NOT_ACTIVE';
 end if;
 return spa_private.payroll_run_save_before_notice(p_from,p_to,coalesce(v.id,p_rule),p_finalize);
end $$;

-- Schema installation leaves the preceding rule in effect until the owner
-- activates the explicitly dated, mapped policy.
create function public.spa_payroll_notice_activate(p_rule uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726001);
 perform pg_advisory_xact_lock(726005);
 perform pg_advisory_xact_lock(726099);
 select * into v from public.spa_payroll_rule_versions where id=p_rule and calculation_engine='notice_v1' and status='draft';
 if v.id is null then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 if v.effective_from>(now() at time zone 'Asia/Taipei')::date then raise exception 'FUTURE_PAYROLL_ACTIVATION_NOT_SUPPORTED'; end if;
 if exists(select 1 from public.spa_payroll_rule_versions where status='active' and effective_from>=v.effective_from)
  or exists(select 1 from public.spa_payroll_runs where status='finalized' and period_end>=v.effective_from)
 then raise exception 'PAYROLL_NOTICE_EFFECTIVE_DATE'; end if;
 if spa_private.payroll_notice_has_earlier_activity(v.effective_from) then raise exception 'PAYROLL_NOTICE_CUTOVER_ACTIVITY'; end if;
 if exists(select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
  where j.work_category='technician' and s.active and s.employment_status='active' and s.archived_at is null
   and not exists(select 1 from spa_private.payroll_notice_staff a where a.rule_id=p_rule and a.staff_id=s.id))
 then raise exception 'PAYROLL_CLASSIFICATION_REQUIRED'; end if;
 if exists(select 1 from public.spa_packages where (created_at at time zone 'Asia/Taipei')::date>=v.effective_from and payroll_seller_id is null)
 then raise exception 'PAYROLL_NOTICE_UNATTRIBUTED_PACKAGES'; end if;
 -- The preceding active version remains available for dates before this one.
 update public.spa_payroll_rule_versions set status='active' where id=p_rule;
 update public.spa_packages p set payroll_sale_bonus_cents=round(p.paid_cents*0.05)::bigint
 from spa_private.payroll_notice_staff s where s.rule_id=p_rule and s.staff_id=p.payroll_seller_id
  and (p.created_at at time zone 'Asia/Taipei')::date>=v.effective_from and p.payroll_sale_bonus_cents=0;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and period_end>=v.effective_from;
 perform spa_private.audit('payroll.notice_activated',p_rule::text,jsonb_build_object('effective_from',v.effective_from));
end $$;

create function public.spa_payroll_notice_pass(p_rule uuid,p_staff uuid,p_on date,p_rank int) returns void
language plpgsql security definer set search_path='' as $$
declare a spa_private.payroll_notice_staff; v public.spa_payroll_rule_versions; old_rate int; new_rate int;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726005);
 perform pg_advisory_xact_lock(726099);
 select * into v from public.spa_payroll_rule_versions where id=p_rule and calculation_engine='notice_v1' and status='active';
 select * into a from spa_private.payroll_notice_staff where rule_id=p_rule and staff_id=p_staff;
 if v.id is null or a.category is null or a.category not in ('01','02') or p_rank not between 2 and 6
  or p_on is null or p_on<v.effective_from or p_on>(now() at time zone 'Asia/Taipei')::date
  or p_rule is distinct from spa_private.payroll_notice_rule_on(p_on) then raise exception 'INVALID_INPUT'; end if;
 if a.passed_on=p_on and a.passed_rank_no=p_rank then return; end if;
 select coalesce(a.start_bps,case a.category when '01' then r.full_time_start_bps else r.monthly_start_bps end)
 into old_rate from spa_private.payroll_notice_ranks r where r.rule_id=p_rule and r.rank_no=a.rank_no;
 select case a.category when '01' then r.full_time_start_bps else r.monthly_start_bps end
 into new_rate from spa_private.payroll_notice_ranks r where r.rule_id=p_rule and r.rank_no=p_rank;
 if old_rate is distinct from 0 or coalesce(new_rate,0)<=0 then raise exception 'PAYROLL_NOTICE_PROBATION_REQUIRED'; end if;
 if exists(select 1 from public.spa_payroll_runs where status='finalized' and period_end>=least(p_on,a.passed_on))
 then raise exception 'PAYROLL_LOCKED'; end if;
 update spa_private.payroll_notice_staff set passed_on=p_on,passed_rank_no=p_rank where rule_id=p_rule and staff_id=p_staff;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and period_end>=least(p_on,a.passed_on);
 perform spa_private.audit('payroll.notice_probation_passed',p_staff::text,jsonb_build_object('effective_from',p_on,'rank',p_rank,'version',p_rule));
end $$;

alter function spa_private.sale_commission_rate(uuid,text,date,boolean,uuid) rename to sale_commission_rate_before_notice;
create function spa_private.sale_commission_rate(p_staff uuid,p_kind text,p_on date,p_self_sourced boolean default false,p_rule uuid default null) returns int
language plpgsql stable security definer set search_path='' as $$
declare n spa_private.payroll_notices; a spa_private.payroll_notice_staff; rule uuid:=coalesce(p_rule,spa_private.payroll_notice_rule_on(p_on));
begin
 select * into n from spa_private.payroll_notices where rule_id=rule;
 if n.rule_id is null then return spa_private.sale_commission_rate_before_notice(p_staff,p_kind,p_on,p_self_sourced,p_rule); end if;
 select * into a from spa_private.payroll_notice_staff where rule_id=rule and staff_id=p_staff;
 if p_kind='product' and a.category is not null then return 500; end if;
 if p_kind='service' and a.category='04' then
  if p_on<a.contract_from then return 0; end if;
  return case when p_on<(coalesce(a.credited_from,a.contract_from)+interval '6 months')::date then 3000 else 4000 end;
 end if;
 return spa_private.sale_commission_rate_before_notice(p_staff,p_kind,p_on,p_self_sourced,
  coalesce((select id from public.spa_payroll_rule_versions where status='active' and calculation_engine<>'notice_v1' and effective_from<=p_on order by effective_from desc,version_no desc limit 1),rule));
end $$;

alter function public.spa_payroll_rule_activate(uuid) set schema spa_private;
alter function spa_private.spa_payroll_rule_activate(uuid) rename to payroll_rule_activate_before_notice;
create function public.spa_payroll_rule_activate(p_rule uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 if exists(select 1 from public.spa_payroll_rule_versions where calculation_engine='notice_v1' and (id=p_rule or status='active'))
 then raise exception 'PAYROLL_NOTICE_NOT_ACTIVE'; end if;
 perform spa_private.payroll_rule_activate_before_notice(p_rule);
end $$;

alter function public.spa_payroll_rule_create(text,date,int,boolean,int,int,int) set schema spa_private;
alter function spa_private.spa_payroll_rule_create(text,date,int,boolean,int,int,int) rename to payroll_rule_create_before_notice;
create function public.spa_payroll_rule_create(p_name text,p_effective date,p_divisor int,p_include_commission boolean,p_monthly_limit int,p_agreed_limit int,p_quarter_limit int) returns uuid
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 if exists(select 1 from public.spa_payroll_rule_versions where calculation_engine='notice_v1' and status='active')
 then raise exception 'PAYROLL_NOTICE_NOT_ACTIVE'; end if;
 return spa_private.payroll_rule_create_before_notice(p_name,p_effective,p_divisor,p_include_commission,p_monthly_limit,p_agreed_limit,p_quarter_limit);
end $$;

revoke all on function spa_private.payroll_notice_lines(uuid,date,date,uuid),spa_private.payroll_notice_has_earlier_activity(date),spa_private.payroll_preview_before_notice(date,date,uuid),spa_private.payroll_preview(date,date,uuid),
 spa_private.payroll_source_packet_before_notice(uuid,date,date,uuid,jsonb),spa_private.payroll_source_packet(uuid,date,date,uuid,jsonb),
 spa_private.sale_commission_rate_before_notice(uuid,text,date,boolean,uuid),spa_private.sale_commission_rate(uuid,text,date,boolean,uuid),
 spa_private.payroll_run_save_before_notice(date,date,uuid,boolean),spa_private.payroll_rule_activate_before_notice(uuid),spa_private.payroll_rule_create_before_notice(text,date,int,boolean,int,int,int),
 public.spa_payroll_run_save(date,date,uuid,boolean),public.spa_payroll_notice_activate(uuid),public.spa_payroll_notice_pass(uuid,uuid,date,int),public.spa_payroll_rule_activate(uuid),public.spa_payroll_rule_create(text,date,int,boolean,int,int,int) from public,anon,authenticated;
grant execute on function public.spa_payroll_run_save(date,date,uuid,boolean),public.spa_payroll_notice_activate(uuid),public.spa_payroll_notice_pass(uuid,uuid,date,int),public.spa_payroll_rule_activate(uuid),public.spa_payroll_rule_create(text,date,int,boolean,int,int,int) to authenticated,service_role;
grant execute on function spa_private.sale_commission_rate(uuid,text,date,boolean,uuid) to service_role;
notify pgrst,'reload schema';
commit;
