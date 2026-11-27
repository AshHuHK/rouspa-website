begin;

-- HR owns dated classifications. Policies own only calculation parameters.
create table spa_private.payroll_classifications (
 id uuid primary key default gen_random_uuid(),
 staff_id uuid not null references public.spa_staff,
 effective_on date not null check(effective_on>='1900-01-01'),
 category text check(category in ('01','02','03','04')),
 rank_no int check(rank_no between 1 and 6),
 job_title_id uuid references public.spa_job_titles,
 employment_type_code text references public.spa_employment_types,
 start_bps int check(start_bps in (0,500,1000,1500,2000,2500,3000)),
 contract_from date,credited_from date,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 updated_by uuid references auth.users,
 unique(staff_id,effective_on),
 check(category<>'02' or start_bps is null or start_bps<=2500),
 check((category is null and rank_no is null) or (category in ('01','02') and rank_no is not null)
  or (category in ('03','04') and rank_no is null)),
 check(category<>'04' or (contract_from is not null and (credited_from is null or credited_from<=contract_from)))
);
alter table spa_private.payroll_classifications enable row level security;
revoke all on spa_private.payroll_classifications from public,anon,authenticated;
alter table public.spa_staff add column contract_credited_from date;

-- Seed explicit existing HR choices; published/finalized wage packets remain
-- untouched. Preserve the earlier trial and its recorded pass date when present.
insert into spa_private.payroll_classifications(staff_id,effective_on,category,rank_no,job_title_id,employment_type_code,start_bps,contract_from,credited_from)
select s.id,coalesce(s.hire_date,'1900-01-01'::date),
 s.payroll_category_code,
 case when s.payroll_category_code in ('01','02') then coalesce(case when a.passed_on is not null then a.rank_no end,
 array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code)) end,
 s.job_title_id,s.employment_type_code,a.start_bps,
 case when s.payroll_category_code='04' then coalesce(s.contract_started_on,a.contract_from) end,
 case when s.payroll_category_code='04' then a.credited_from end
from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
left join lateral(select n.*,v.effective_from from spa_private.payroll_notice_staff n
 join public.spa_payroll_rule_versions v on v.id=n.rule_id where n.staff_id=s.id
 order by v.effective_from desc,v.version_no desc limit 1)a on true
where not j.legacy and (j.work_category<>'technician' or s.payroll_category_code is not null)
 and (s.payroll_category_code is distinct from '04' or coalesce(s.contract_started_on,a.contract_from) is not null);
insert into spa_private.payroll_classifications(staff_id,effective_on,category,rank_no,job_title_id,employment_type_code)
select distinct on(s.id,a.passed_on) s.id,a.passed_on,a.category,a.passed_rank_no,s.job_title_id,s.employment_type_code
from public.spa_staff s join spa_private.payroll_notice_staff a on a.staff_id=s.id
join public.spa_payroll_rule_versions v on v.id=a.rule_id
where a.passed_on is not null and s.payroll_category_code=a.category
order by s.id,a.passed_on,v.effective_from desc,v.version_no desc
on conflict(staff_id,effective_on) do nothing;
update public.spa_staff s set contract_credited_from=h.credited_from
from spa_private.payroll_classifications h where h.staff_id=s.id and h.category='04' and h.credited_from is not null;

create function spa_private.payroll_classification_on(p_staff uuid,p_date date,p_rule uuid default null)
returns table(classification_id uuid,effective_on date,category text,rank_no int,start_bps int,
 contract_from date,credited_from date,job_title_id uuid,employment_type_code text)
language sql stable security definer set search_path='' as $$
 with history as (
  select h.id,h.effective_on,h.category,h.rank_no,h.start_bps,h.contract_from,h.credited_from,h.job_title_id,h.employment_type_code,1 priority
  from spa_private.payroll_classifications h where h.staff_id=p_staff and h.effective_on<=p_date
  order by h.effective_on desc limit 1
 ), legacy as (
  select null::uuid,v.effective_from,a.category,
   case when a.passed_on<=p_date then a.passed_rank_no else a.rank_no end,
   case when a.passed_on<=p_date then null::int else a.start_bps end,
   a.contract_from,a.credited_from,s.job_title_id,s.employment_type_code,2
  from spa_private.payroll_notice_staff a join public.spa_payroll_rule_versions v on v.id=a.rule_id
  join public.spa_staff s on s.id=a.staff_id
  where a.staff_id=p_staff and a.rule_id=p_rule and not exists(select 1 from spa_private.payroll_classifications where staff_id=p_staff)
 ), inferred as (
  select null::uuid,coalesce(s.hire_date,'1900-01-01'),
   case when j.work_category='technician' then coalesce(s.payroll_category_code,
    case when s.employment_type_code='contractor' then '04' when s.employment_type_code='full_time' then '01'
     when j.code='pt_technician' then '03' when s.pay_basis='monthly' then '02' else '03' end) end,
   case when j.code like 'ft_%' then array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code) end,
   null::int,s.contract_started_on,s.contract_credited_from,s.job_title_id,s.employment_type_code,3
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
  where s.id=p_staff and not j.legacy and coalesce(s.hire_date,'1900-01-01')<=p_date
   and not exists(select 1 from spa_private.payroll_classifications where staff_id=p_staff)
 )
 select x.id,x.effective_on,x.category,x.rank_no,x.start_bps,x.contract_from,x.credited_from,x.job_title_id,x.employment_type_code
 from(select * from history union all select * from legacy union all select * from inferred)x order by priority limit 1
$$;
revoke all on function spa_private.payroll_classification_on(uuid,date,uuid) from public,anon,authenticated;

create or replace function public.spa_staff_profile_save_v2(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid; old public.spa_staff; j public.spa_job_titles; category text; rank int;
 employment text:=p_payload->>'employment_type_code'; effective date:=coalesce(nullif(p_payload->>'payroll_effective_on','')::date,(now() at time zone 'Asia/Taipei')::date);
 credit date:=nullif(p_payload->>'contract_credited_from','')::date; changed boolean; initial boolean:=nullif(p_payload->>'id','') is null;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726005); perform pg_advisory_xact_lock(726099);
 select * into old from public.spa_staff where id=nullif(p_payload->>'id','')::uuid;
 if old.id is not null and employment='contractor' then
  if not(p_payload?'contract_started_on') then p_payload:=p_payload||jsonb_build_object('contract_started_on',old.contract_started_on); end if;
  if not(p_payload?'contract_credited_from') then credit:=old.contract_credited_from; end if;
 end if;
 select * into j from public.spa_job_titles where id=nullif(p_payload->>'job_title_id','')::uuid;
 category:=case when j.work_category='technician' then coalesce(nullif(p_payload->>'payroll_category_code',''),old.payroll_category_code,
  case when employment='contractor' then '04' when employment='full_time' then '01' when j.code='pt_technician' then '03' when old.pay_basis='monthly' then '02' else '03' end) end;
 rank:=array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code);
 if j.work_category='technician' and not j.legacy and not coalesce(
  (category='01' and employment='full_time' and rank is not null) or(category='02' and employment='part_time' and rank is not null)
  or(category='03' and employment='part_time' and j.code='pt_technician') or(category='04' and employment='contractor' and j.code='contract_technician'),false)
 then raise exception 'JOB_EMPLOYMENT_MISMATCH'; end if;
 if category is distinct from '04' then credit:=null; p_payload:=p_payload||jsonb_build_object('contract_started_on',null,'contract_credited_from',null); end if;
 if credit is not null and (category is distinct from '04' or credit<nullif(p_payload->>'hire_date','')::date or credit>nullif(p_payload->>'contract_started_on','')::date)
 then raise exception 'INVALID_CONTRACT_COOPERATION_DATE'; end if;
 changed:=initial or old.job_title_id is distinct from j.id or old.employment_type_code is distinct from employment
  or old.payroll_category_code is distinct from category or old.contract_started_on is distinct from nullif(p_payload->>'contract_started_on','')::date
  or old.contract_credited_from is distinct from credit or coalesce((p_payload->>'force_classification_change')::boolean,false);
 -- Preserve the previous HR identity before the first dated change (old
 -- clients/direct imports may not yet have a classification history).
 if old.id is not null and not exists(select 1 from spa_private.payroll_classifications where staff_id=old.id) then
  insert into spa_private.payroll_classifications(staff_id,effective_on,category,rank_no,job_title_id,employment_type_code,contract_from,credited_from)
  select old.id,coalesce(old.hire_date,'1900-01-01'),a.category,a.rank_no,a.job_title_id,a.employment_type_code,
   case when a.category='04' then a.contract_from end,case when a.category='04' then a.credited_from end
  from spa_private.payroll_classification_on(old.id,effective-1,null) a
  where (a.category not in ('01','02') or a.rank_no is not null) and (a.category is distinct from '04' or a.contract_from is not null);
 end if;
 -- Reuse existing HR, service-qualification, departure and account checks,
 -- deliberately bypassing the superseded wage-version classification lock.
 result:=spa_private.staff_profile_save_before_hierarchy(p_payload);
 update public.spa_staff set payroll_category_code=category,contract_credited_from=case when category='04' then credit end,
  pay_basis=case category when '01' then 'monthly' when '02' then 'monthly' when '03' then 'hourly' when '04' then 'session' else pay_basis end where id=result;
 if changed and not j.legacy then
  insert into spa_private.payroll_classifications(staff_id,effective_on,category,rank_no,job_title_id,employment_type_code,start_bps,contract_from,credited_from,updated_by)
  values(result,effective,category,case when category in ('01','02') then rank end,j.id,employment,
   case when category in ('01','02') then nullif(p_payload->>'payroll_start_bps','')::int end,
   case when category='04' then nullif(p_payload->>'contract_started_on','')::date end,case when category='04' then credit end,auth.uid())
  on conflict(staff_id,effective_on) do update set category=excluded.category,rank_no=excluded.rank_no,job_title_id=excluded.job_title_id,
   employment_type_code=excluded.employment_type_code,start_bps=excluded.start_bps,contract_from=excluded.contract_from,credited_from=excluded.credited_from,
   updated_at=now(),updated_by=auth.uid();
  update public.spa_payroll_runs set needs_recalculation=true where status='draft' and period_end>=effective;
  perform spa_private.audit('staff.payroll_classification_changed',result::text,jsonb_build_object('effective_on',effective,'category',category,'rank',rank));
 end if;
 return result;
end $$;

-- Old clients are routed into HR, never back into a policy/person assignment.
create or replace function public.spa_payroll_notice_assign(p_rule uuid,p_staff uuid,p_assignment jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare s public.spa_staff; title public.spa_job_titles; category text:=p_assignment->>'category'; title_code text; effective date;
begin
 perform spa_private.require_permission('team.manage');
 select * into s from public.spa_staff where id=p_staff and archived_at is null;
 if not found then raise exception 'NOT_FOUND'; end if;
 title_code:=case category when '01' then (array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'])[(p_assignment->>'rank_no')::int]
  when '02' then (array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'])[(p_assignment->>'rank_no')::int]
  when '03' then 'pt_technician' when '04' then 'contract_technician' end;
 select * into title from public.spa_job_titles where spa_job_titles.code=title_code and active;
 if title.id is null then raise exception 'JOB_CLASSIFICATION_REQUIRED'; end if;
 effective:=coalesce(nullif(p_assignment->>'effective_on','')::date,(select effective_from from public.spa_payroll_rule_versions where id=p_rule),(now() at time zone 'Asia/Taipei')::date);
 perform public.spa_staff_profile_save_v2(to_jsonb(s)||jsonb_build_object('id',s.id,'job_title_id',title.id,'title',title.name,
  'employment_type_code',case category when '01' then 'full_time' when '04' then 'contractor' else 'part_time' end,
  'payroll_category_code',category,'payroll_effective_on',effective,'force_classification_change',true,'payroll_start_bps',p_assignment->'start_bps',
  'contract_started_on',case when category='04' then p_assignment->>'contract_from' end,'contract_credited_from',p_assignment->>'credited_from',
  'services',(select coalesce(jsonb_agg(service_id),'[]') from public.spa_staff_services where staff_id=s.id and enabled)));
end $$;
create or replace function public.spa_payroll_notice_pass(p_rule uuid,p_staff uuid,p_on date,p_rank int) returns void
language plpgsql security definer set search_path='' as $$
declare a record;
begin
 perform spa_private.require_permission('team.manage');
 select * into a from spa_private.payroll_classification_on(p_staff,p_on,p_rule);
 if a.category not in ('01','02') or p_rank not between 2 and 6 then raise exception 'INVALID_INPUT'; end if;
 perform public.spa_payroll_notice_assign(p_rule,p_staff,jsonb_build_object('category',a.category,'rank_no',p_rank,'effective_on',p_on));
end $$;

create or replace function spa_private.payroll_notice_lines(p_staff uuid,p_from date,p_to date,p_rule uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with units as (
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
  select u.*,case a.category when '01' then coalesce(a.start_bps,r.full_time_start_bps) when '02' then coalesce(a.start_bps,r.monthly_start_bps) when '03' then 500 else 0 end ordinary_start_bps,
   a.category,a.rank_no,a.classification_id,a.effective_on classification_effective_on,a.contract_from,a.credited_from,
   case a.category when '01' then n.full_time_threshold_minutes when '02' then n.monthly_threshold_minutes else n.hourly_threshold_minutes end threshold,
   n.step_minutes,case when a.category='02' then 2500 else 3000 end cap_bps
  from units u cross join spa_private.payroll_notices n
  join public.spa_payroll_rule_versions v on v.id=n.rule_id
  cross join lateral spa_private.payroll_classification_on(p_staff,u.date,p_rule) a
  left join spa_private.payroll_notice_ranks r on r.rule_id=p_rule and r.rank_no=a.rank_no
  where n.rule_id=p_rule and u.date>=v.effective_from and a.category is not null
 ), chronological as (
  select u.*,
   coalesce(sum(duration_minutes) filter (where ordinary_start_bps>0) over monthly,0)::bigint before_minutes,
   case when ordinary_start_bps>0 then duration_minutes else 0 end ordinary_qualified_minutes
  from qualified u
  window monthly as (partition by date_trunc('month',date::timestamp),category
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

-- One row per dated HR segment. Monthly wages use calendar-day fractions;
-- approved net attendance is counted only on that day's hourly segment.
create function spa_private.payroll_base_segments(p_staff uuid,p_from date,p_to date,p_rule uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with days as (
  select d::date work_day,a.*,extract(day from(date_trunc('month',d)+interval '1 month - 1 day'))::int month_days,
   case a.category when '01' then 3100000 when '02' then n.monthly_base_cents when '03' then 20500 when '04' then 0 else c.base_pay_cents end rate,
   case when a.category in ('01','02') then 'monthly' when a.category='03' then 'hourly' when a.category='04' then 'session' else c.pay_basis end basis,
   coalesce((select sum(greatest(0,floor(extract(epoch from(e.ended_at-e.started_at))/60)::int-e.break_minutes)) from public.spa_time_entries e where e.staff_id=p_staff and e.status='approved' and e.work_date=d::date),0)::bigint minutes
  from generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d
  cross join lateral spa_private.payroll_classification_on(p_staff,d::date,p_rule) a
  join public.spa_staff s on s.id=p_staff
  join spa_private.payroll_notices n on n.rule_id=p_rule
  left join public.spa_payroll_version_profiles c on c.rule_version_id=p_rule and c.job_title_id=a.job_title_id and c.employment_type_code=a.employment_type_code
  where (s.hire_date is null or d::date>=s.hire_date) and (s.departed_on is null or d::date<=s.departed_on)
 ), segments as (
  select classification_id,effective_on,category,rank_no,job_title_id,employment_type_code,rate,basis,month_days,
   min(work_day) from_date,max(work_day) to_date,count(*) day_count,sum(minutes) work_minutes,
   case basis when 'monthly' then (round(rate*extract(day from max(work_day))::numeric/month_days)-round(rate*(extract(day from min(work_day))-1)::numeric/month_days))::bigint
    when 'hourly' then round(rate*sum(minutes)/60.0)::bigint else 0 end amount_cents
  from days group by classification_id,effective_on,category,rank_no,job_title_id,employment_type_code,rate,basis,month_days
 ) select coalesce(jsonb_agg(to_jsonb(s) order by from_date),'[]') from segments s
$$;
create function spa_private.payroll_product_rate(p_staff uuid,p_on date,p_rule uuid,p_snapshot int) returns int
language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from spa_private.payroll_classification_on(p_staff,p_on,p_rule) a where a.category is not null) then 500 else coalesce(p_snapshot,0) end
$$;


create or replace function spa_private.payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v public.spa_payroll_rule_versions; n spa_private.payroll_notices; assignment record; base_segments jsonb; rank spa_private.payroll_notice_ranks; passed_rank spa_private.payroll_notice_ranks;
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
  from public.spa_staff s
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
  select a.*,null::date passed_on,null::int passed_rank_no into assignment from spa_private.payroll_classification_on(person,p_to,v.id) a;
  if assignment.category is null and not exists(select 1 from spa_private.payroll_classifications h where h.staff_id=person and h.category is not null and h.effective_on<=p_to) and not exists(select 1 from public.spa_job_titles where id=(row->>'job_title_id')::uuid and work_category='technician') then
   -- Use the copied prior configuration for people outside the four technician categories.
   row:=row||jsonb_build_object('bonus_cents',entered_bonus+voucher,'package_bonus_cents',voucher,'entered_bonus_cents',entered_bonus,
    'total_cents',greatest(0,coalesce((row->'calculation'->>'component_total_before_floor_cents')::bigint,(row->>'total_cents')::bigint)+voucher));
   result:=result||jsonb_build_array(row);
   continue;
  end if;
  select * into rank from spa_private.payroll_notice_ranks where rule_id=v.id and rank_no=assignment.rank_no;
  select * into passed_rank from spa_private.payroll_notice_ranks where rule_id=v.id and rank_no=assignment.passed_rank_no;
  pending:=assignment.category is null and not exists(select 1 from spa_private.payroll_classifications h where h.staff_id=person and h.category is not null and h.effective_on<=p_to);
  lines:=spa_private.payroll_notice_lines(person,p_from,p_to,v.id);
  select coalesce(sum((x->>'service_commission_cents')::bigint),0),coalesce(sum((x->>'designated_bonus_cents')::bigint),0),
   coalesce(sum((x->>'duration_minutes')::int),0),coalesce(sum((x->>'net_cents')::bigint),0),
   coalesce(sum((x->>'net_cents')::bigint) filter(where (x->>'designated')::boolean),0),
   count(*) filter(where (x->>'designated')::boolean),coalesce(bool_or((x->>'pre_contract')::boolean),false),
   coalesce(sum((x->>'ordinary_qualified_minutes')::int),0)
  into service,designated,minutes,income,designated_income,designated_count,pre_contract,ordinary_minutes from jsonb_array_elements(lines)x;
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
  base_segments:=spa_private.payroll_base_segments(person,p_from,p_to,v.id);
  select coalesce(sum((x->>'amount_cents')::bigint),0) into base from jsonb_array_elements(base_segments)x;
  if assignment.category is null then
   base_rate:=coalesce((base_segments->-1->>'rate')::bigint,0); basis:=coalesce(base_segments->-1->>'basis','session');
   select name into title from public.spa_job_titles where id=assignment.job_title_id;
   employment:=assignment.employment_type_code;
  end if;
  product_rate:=500;
  select coalesce(sum(round(i.net_total_cents*spa_private.payroll_product_rate(person,(o.paid_at at time zone 'Asia/Taipei')::date,v.id,i.commission_bps_snapshot)/10000.0)::bigint),0)
  into product from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
  where i.staff_id=person and i.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between greatest(p_from,v.effective_from) and p_to;
  product:=product+product_return;
  select coalesce(round(sum(case when a.category in ('01','02') then
    ((case a.category when '01' then 3100000 else n.monthly_base_cents end)+case when v.include_regular_commission then service+product+designated else 0 end)/v.hourly_divisor::numeric
    when a.category='03' then 20500 when a.category is null and c.pay_basis='monthly' then (c.base_pay_cents+case when v.include_regular_commission then service+product+designated else 0 end)/v.hourly_divisor::numeric when a.category is null and c.pay_basis='hourly' then c.base_pay_cents else 0 end *allocated.weighted_minutes/600000.0))::bigint,0),
   coalesce(sum(case when a.category='04' then o.minutes else greatest(0,o.minutes-allocated.covered_minutes) end),0)
  into overtime,unpriced
  from (select o.work_date,o.overtime_type,sum(o.minutes)::int minutes from public.spa_overtime_entries o
   where o.staff_id=person and o.status='approved' and o.work_date between p_from and p_to group by o.work_date,o.overtime_type)o
  cross join lateral spa_private.payroll_classification_on(person,o.work_date,v.id) a
  left join public.spa_payroll_version_profiles c on c.rule_version_id=v.id and c.job_title_id=a.job_title_id and c.employment_type_code=a.employment_type_code
  cross join lateral (
   select coalesce(sum(greatest(0,least(o.minutes,r.end_minute)-r.start_minute)*r.multiplier_bps),0) weighted_minutes,
    coalesce(sum(greatest(0,least(o.minutes,r.end_minute)-r.start_minute)),0) covered_minutes
   from public.spa_payroll_overtime_rates r where r.rule_version_id=v.id and r.employment_type_code=a.employment_type_code and r.overtime_type=o.overtime_type
  )allocated;
  total:=base+service+designated+product+overtime+entered_bonus+voucher+coalesce((row->>'allowance_cents')::bigint,0)-coalesce((row->>'deduction_cents')::bigint,0);
  ready:=not pending and not pre_contract and not cutover_attention;
  warning:=case when pending then '請設定這位技師的薪資類別' when pre_contract then '本期包含承攬開始前的服務或出勤，請先核對原聘僱期間'
   when cutover_attention then '本月補登了啟用日前的紀錄，請先核對切換月薪資'
   when total<0 and (voucher<0 or product_return<0) then '本期報酬不足扣回退款抽成，請核對差額'
   else '' end;
  result:=result||jsonb_build_array(row||jsonb_build_object(
   'role',title,'employment_type',title,'employment_type_code',employment,'work_category',coalesce((select work_category from public.spa_job_titles where id=assignment.job_title_id),'technician'),
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
    'calculation_engine','notice_v1','hr_segmented',true,'base_segments',base_segments,'component_total_before_floor_cents',total,'step_minutes',n.step_minutes,'threshold_minutes',threshold,
    'probation_passed_on',assignment.passed_on,'contract_credited_from',assignment.credited_from,
    'contract_anniversary',case when assignment.category='04' then (coalesce(assignment.credited_from,assignment.contract_from)+interval '6 months')::date end
   )));
 end loop;
 return result;
end $$;

create or replace function spa_private.payroll_source_packet(p_staff uuid,p_from date,p_to date,p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare packet jsonb:=spa_private.payroll_source_packet_before_notice(p_staff,p_from,p_to,p_rule,p_wage);
 lines jsonb; sales jsonb; totals jsonb; refs jsonb; products jsonb; rate int; source_key text;
begin
 if not exists(select 1 from spa_private.payroll_notices where rule_id=p_rule) then return packet; end if;
 sales:=spa_private.payroll_notice_sales(p_staff,p_from,p_to);
 packet:=jsonb_set(packet,'{sources,notice_sales}',sales,true);
 if p_wage->>'notice_category' is null and not coalesce((p_wage->'calculation'->>'hr_segmented')::boolean,false) then return packet; end if;
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
 select coalesce(jsonb_agg(x||jsonb_build_object('snapshot_commission_cents',
  round((x->>'net_cents')::bigint*spa_private.payroll_product_rate(p_staff,(x->>'date')::date,p_rule,(x->>'commission_bps_snapshot')::int)/10000.0)::bigint,
  'commission_bps_snapshot',spa_private.payroll_product_rate(p_staff,(x->>'date')::date,p_rule,(x->>'commission_bps_snapshot')::int))),'[]')
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
   where r.rule_version_id=p_rule and (r.employment_type_code=p_wage->>'employment_type_code' or r.employment_type_code in(select x->>'employment_type_code' from jsonb_array_elements(coalesce(p_wage->'calculation'->'base_segments','[]'))x))),'[]'));
 return packet||jsonb_build_object('source_totals',totals,'rule_reference',refs,'schema_version',3);
end $$;

create or replace function spa_private.payroll_notice_save_before_flat_monthly(p_rule uuid,p_settings jsonb,p_ranks jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 if not exists(select 1 from public.spa_payroll_rule_versions where id=p_rule and status in ('draft','active') and calculation_engine='notice_v1')
 then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 if jsonb_typeof(p_ranks) is distinct from 'array' or jsonb_array_length(p_ranks)<>6
    or (select count(distinct r.rank_no) from jsonb_to_recordset(p_ranks) r(rank_no int) where r.rank_no between 1 and 6)<>6
 then raise exception 'INVALID_INPUT'; end if;
 update spa_private.payroll_notices set
  full_time_threshold_minutes=(p_settings->>'full_time_threshold_minutes')::int,
  monthly_threshold_minutes=(p_settings->>'monthly_threshold_minutes')::int,
  hourly_threshold_minutes=(p_settings->>'hourly_threshold_minutes')::int,
  step_minutes=(p_settings->>'step_minutes')::int
 where rule_id=p_rule;
 update spa_private.payroll_notice_ranks r set
  full_time_start_bps=n.full_time_start_bps,monthly_start_bps=n.monthly_start_bps,monthly_base_cents=n.monthly_base_cents
 from jsonb_to_recordset(p_ranks) n(rank_no int,full_time_start_bps int,monthly_start_bps int,monthly_base_cents bigint)
 where r.rule_id=p_rule and r.rank_no=n.rank_no;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and rule_version_id=p_rule;
 perform spa_private.audit('payroll.notice_saved',p_rule::text,'{}');
end $$;

create or replace function public.spa_payroll_notice_setup(p_effective date) returns uuid
language plpgsql security definer set search_path='' as $$
declare source public.spa_payroll_rule_versions; result uuid; next_no int;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 if p_effective is null then raise exception 'INVALID_DATE'; end if;
 select * into source from public.spa_payroll_rule_versions where status='active'
 order by effective_from desc,version_no desc limit 1;
 if source.id is null or p_effective<=source.effective_from then raise exception 'PAYROLL_NOTICE_EFFECTIVE_DATE'; end if;
 if extract(day from p_effective)<>1 and (source.calculation_engine='notice_v1' or p_effective<>(now() at time zone 'Asia/Taipei')::date)
 then raise exception 'PAYROLL_FULL_MONTH_REQUIRED'; end if;
 if exists(select 1 from public.spa_payroll_rule_versions where calculation_engine='notice_v1' and status='draft') then raise exception 'PAYROLL_NOTICE_DRAFT_EXISTS'; end if;
 select coalesce(max(version_no),0)+1 into next_no from public.spa_payroll_rule_versions;
 insert into public.spa_payroll_rule_versions(version_no,name,effective_from,status,hourly_divisor,include_regular_commission,monthly_overtime_limit_minutes,agreed_monthly_limit_minutes,quarterly_overtime_limit_minutes,created_by,calculation_engine)
 values(next_no,'技師薪資制度告知書 03-1',p_effective,'draft',source.hourly_divisor,source.include_regular_commission,source.monthly_overtime_limit_minutes,source.agreed_monthly_limit_minutes,source.quarterly_overtime_limit_minutes,auth.uid(),'notice_v1')
 returning id into result;
 insert into spa_private.payroll_notices(rule_id) values(result);
 insert into spa_private.payroll_notice_ranks
 select result,n,(n-1)*500,(n-1)*500,(array[25200,25600,25600,26000,26000,26600])[n]*100
 from generate_series(1,6) n;
 if source.calculation_engine='notice_v1' then
  update spa_private.payroll_notices n set full_time_threshold_minutes=p.full_time_threshold_minutes,monthly_threshold_minutes=p.monthly_threshold_minutes,
   hourly_threshold_minutes=p.hourly_threshold_minutes,step_minutes=p.step_minutes
   from spa_private.payroll_notices p where n.rule_id=result and p.rule_id=source.id;
  update spa_private.payroll_notice_ranks n set full_time_start_bps=p.full_time_start_bps,monthly_start_bps=p.monthly_start_bps,monthly_base_cents=p.monthly_base_cents
  from spa_private.payroll_notice_ranks p where n.rule_id=result and p.rule_id=source.id and p.rank_no=n.rank_no;
 end if;
 insert into public.spa_payroll_overtime_rates select result,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from public.spa_payroll_overtime_rates where rule_version_id=source.id;
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode)
 select result,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode
 from public.spa_payroll_commission_tiers where rule_version_id=source.id;
 insert into public.spa_payroll_version_profiles
 select result,job_title_id,employment_type_code,pay_basis,base_pay_cents,service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,minimum_service_minutes,commission_start_service_minutes,service_commission_mode,self_sourced_commission_bps,contractor_count_scope,service_policy_status,active,auth.uid(),now()
 from public.spa_payroll_version_profiles where rule_version_id=source.id;
 update spa_private.payroll_notices set monthly_base_cents=coalesce((select monthly_base_cents from spa_private.payroll_notices where rule_id=source.id),2520000) where rule_id=result;
 update spa_private.payroll_notice_ranks set monthly_base_cents=(select monthly_base_cents from spa_private.payroll_notices where rule_id=result) where rule_id=result;
 perform spa_private.audit('payroll.notice_created',result::text,jsonb_build_object('effective_from',p_effective,'source',source.id));
 return result;
end $$;

create or replace function public.spa_payroll_notice_get(p_rule uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return (select to_jsonb(n)||jsonb_build_object(
  'ranks',(select jsonb_agg(to_jsonb(r)-'rule_id' order by rank_no) from spa_private.payroll_notice_ranks r where r.rule_id=p_rule),
  'assignments','[]'::jsonb,'technician_ids','[]'::jsonb)
 from spa_private.payroll_notices n where n.rule_id=p_rule);
end $$;

create or replace function public.spa_payroll_notice_activate(p_rule uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726001);
 perform pg_advisory_xact_lock(726005);
 perform pg_advisory_xact_lock(726099);
 select * into v from public.spa_payroll_rule_versions where id=p_rule and calculation_engine='notice_v1' and status='draft';
 if v.id is null then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 if v.effective_from>(now() at time zone 'Asia/Taipei')::date and extract(day from v.effective_from)<>1 then raise exception 'PAYROLL_FULL_MONTH_REQUIRED'; end if;
 if exists(select 1 from public.spa_payroll_rule_versions where status='active' and effective_from>=v.effective_from)
  or exists(select 1 from public.spa_payroll_runs where status='finalized' and period_end>=v.effective_from)
 then raise exception 'PAYROLL_NOTICE_EFFECTIVE_DATE'; end if;
 if spa_private.payroll_notice_has_earlier_activity(v.effective_from) then raise exception 'PAYROLL_NOTICE_CUTOVER_ACTIVITY'; end if;
 if exists(select 1 from public.spa_packages where (created_at at time zone 'Asia/Taipei')::date>=v.effective_from and payroll_seller_id is null)
 then raise exception 'PAYROLL_NOTICE_UNATTRIBUTED_PACKAGES'; end if;
 -- The preceding active version remains available for dates before this one.
 update public.spa_payroll_rule_versions set status='active' where id=p_rule;
 update public.spa_packages p set payroll_sale_bonus_cents=round(p.paid_cents*0.05)::bigint
 where exists(select 1 from spa_private.payroll_classification_on(p.payroll_seller_id,(p.created_at at time zone 'Asia/Taipei')::date,p_rule)a where a.category is not null)
  and (p.created_at at time zone 'Asia/Taipei')::date>=v.effective_from and p.payroll_sale_bonus_cents=0;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and period_end>=v.effective_from;
 perform spa_private.audit('payroll.notice_activated',p_rule::text,jsonb_build_object('effective_from',v.effective_from));
end $$;

create or replace function spa_private.sale_commission_rate(p_staff uuid,p_kind text,p_on date,p_self_sourced boolean default false,p_rule uuid default null) returns int
language plpgsql stable security definer set search_path='' as $$
declare n spa_private.payroll_notices; a record; rule uuid:=coalesce(p_rule,spa_private.payroll_notice_rule_on(p_on));
begin
 select * into n from spa_private.payroll_notices where rule_id=rule;
 if n.rule_id is null then return spa_private.sale_commission_rate_before_notice(p_staff,p_kind,p_on,p_self_sourced,p_rule); end if;
 select * into a from spa_private.payroll_classification_on(p_staff,p_on,rule);
 if p_kind='product' and a.category is not null then return 500; end if;
 if p_kind='service' and a.category in ('01','02','03') then
  if a.category='03' then return 500; end if;
  return (select coalesce(a.start_bps,case a.category when '01' then r.full_time_start_bps else r.monthly_start_bps end) from spa_private.payroll_notice_ranks r where r.rule_id=rule and r.rank_no=a.rank_no);
 end if;
 if p_kind='service' and a.category='04' then
  if p_on<a.contract_from then return 0; end if;
  return case when p_on<(coalesce(a.credited_from,a.contract_from)+interval '6 months')::date then 3000 else 4000 end;
 end if;
 return spa_private.sale_commission_rate_before_notice(p_staff,p_kind,p_on,p_self_sourced,
  coalesce((select id from public.spa_payroll_rule_versions where status='active' and calculation_engine<>'notice_v1' and effective_from<=p_on order by effective_from desc,version_no desc limit 1),rule));
end $$;

create or replace function public.spa_package_sell_v2(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text,p_seller uuid default null) returns void
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
   if exists(select 1 from spa_private.payroll_classification_on(p_seller,day,rule) where category is not null) then
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

create or replace function public.spa_payroll_notice_return(p_request uuid,p_kind text,p_source uuid,p_returned_on date,p_amount bigint,p_receipt text) returns void
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
  cross join lateral spa_private.payroll_classification_on(i.staff_id,(o.paid_at at time zone 'Asia/Taipei')::date,spa_private.payroll_notice_rule_on((o.paid_at at time zone 'Asia/Taipei')::date)) s
  where s.category is not null and i.id=p_source and i.item_type='product' and o.status='paid';
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

revoke all on function spa_private.payroll_base_segments(uuid,date,date,uuid),spa_private.payroll_product_rate(uuid,date,uuid,int) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
