begin;

-- Job function is independent from login permissions. Retain old titles and
-- historical runs, but require an explicit owner decision for technician rank.
alter table public.spa_job_titles
 add column if not exists work_category text not null default 'legacy',
 add column if not exists allowed_employment_types text[] not null default array['full_time','part_time','contractor'],
 add column if not exists legacy boolean not null default true,
 add column if not exists rank_code text;
alter table public.spa_job_titles add constraint spa_job_titles_work_category_check check(work_category in ('owner','counter','technician','legacy'));
insert into public.spa_employment_types(code,name,display_order) values('owner','店主（單一職位）',1) on conflict(code) do nothing;
update public.spa_job_titles set work_category='technician' where code in ('head_therapist','senior_therapist','therapist','part_time');
update public.spa_job_titles set work_category='owner',allowed_employment_types=array['owner'],legacy=false,rank_code='owner' where code='owner';
update public.spa_job_titles set work_category='counter',allowed_employment_types=array['full_time','part_time'],legacy=false,rank_code='counter' where code='reception';
insert into public.spa_job_titles(code,name,name_en,work_category,allowed_employment_types,legacy,rank_code,display_order) values
 ('ft_probation','試用技師','Probationary technician','technician',array['full_time'],false,'probation',110),
 ('ft_junior','初級技師','Junior technician','technician',array['full_time'],false,'junior',120),
 ('ft_senior_junior','資深初級技師','Senior junior technician','technician',array['full_time'],false,'senior_junior',130),
 ('ft_mid','中階技師','Intermediate technician','technician',array['full_time'],false,'mid',140),
 ('ft_senior_mid','資深中階技師','Senior intermediate technician','technician',array['full_time'],false,'senior_mid',150),
 ('ft_advanced','高階技師','Advanced technician','technician',array['full_time'],false,'advanced',160),
 ('ft_senior_advanced','資深高階技師','Senior advanced technician','technician',array['full_time'],false,'senior_advanced',170),
 ('pt_technician','兼職技師','Part-time technician','technician',array['part_time'],false,'part_time',180),
 ('contract_technician','承攬技師','Contract technician','technician',array['contractor'],false,'contractor',190)
 on conflict(code) do update set name=excluded.name,name_en=excluded.name_en,work_category=excluded.work_category,
  allowed_employment_types=excluded.allowed_employment_types,legacy=false,rank_code=excluded.rank_code;

alter table public.spa_payroll_rule_versions add column if not exists calculation_engine text not null default 'legacy_period_average';
alter table public.spa_payroll_rule_versions add constraint spa_payroll_engine_check check(calculation_engine in ('legacy_period_average','ordered_v2'));
create table public.spa_payroll_version_profiles (
 rule_version_id uuid not null references public.spa_payroll_rule_versions on delete cascade,
 job_title_id uuid not null references public.spa_job_titles,
 employment_type_code text not null references public.spa_employment_types(code),
 pay_basis text not null check(pay_basis in ('monthly','hourly','session')),
 base_pay_cents bigint not null check(base_pay_cents between 0 and 10000000000),
 service_commission_bps int not null check(service_commission_bps between 0 and 10000),
 product_commission_bps int not null check(product_commission_bps between 0 and 10000),
 designated_client_bonus_bps int not null check(designated_client_bonus_bps between 0 and 10000),
 minimum_attendance_minutes int not null check(minimum_attendance_minutes between 0 and 100000),
 minimum_service_minutes int not null default 0 check(minimum_service_minutes between 0 and 100000),
 commission_start_service_minutes int not null check(commission_start_service_minutes between 0 and 100000),
 service_commission_mode text not null check(service_commission_mode in ('ordered_tiers','flat','none')),
 self_sourced_commission_bps int not null default 0 check(self_sourced_commission_bps between 0 and 10000),
 contractor_count_scope text check(contractor_count_scope in ('period','lifetime')),
 service_policy_status text not null default 'confirmed' check(service_policy_status in ('confirmed','needs_confirmation')),
 active boolean not null default true,
 updated_by uuid references auth.users,
 updated_at timestamptz not null default now(),
 primary key(rule_version_id,job_title_id,employment_type_code)
);
alter table public.spa_payroll_version_profiles enable row level security;
revoke all on public.spa_payroll_version_profiles from public,anon,authenticated;
grant all on public.spa_payroll_version_profiles to service_role;

-- One new active version; legacy versions and saved wage packets are retained.
-- Never infer a new technician rank from a display name or elapsed seniority.
do $$
declare source uuid; target uuid; next_no int;
begin
 select id into source from public.spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1;
 select coalesce(max(version_no),0)+1 into next_no from public.spa_payroll_rule_versions;
 update public.spa_payroll_rule_versions set status='archived' where status='active';
 insert into public.spa_payroll_rule_versions(version_no,name,effective_from,status,hourly_divisor,include_regular_commission,
  monthly_overtime_limit_minutes,agreed_monthly_limit_minutes,quarterly_overtime_limit_minutes,calculation_engine)
 select next_no,'技師薪資制度・職能與逐堂抽成',date '2026-10-10','active',coalesce(v.hourly_divisor,240),coalesce(v.include_regular_commission,true),
  coalesce(v.monthly_overtime_limit_minutes,2760),coalesce(v.agreed_monthly_limit_minutes,3240),coalesce(v.quarterly_overtime_limit_minutes,8280),'ordered_v2'
 from (select 1) seed left join public.spa_payroll_rule_versions v on v.id=source returning id into target;
 insert into public.spa_payroll_overtime_rates(rule_version_id,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps)
 select target,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from public.spa_payroll_overtime_rates where rule_version_id=source;
 -- Keep original legacy amounts available for mapping review. Only future
 -- product transactions use the new default; existing sale snapshots survive.
 insert into public.spa_payroll_version_profiles(rule_version_id,job_title_id,employment_type_code,pay_basis,base_pay_cents,
  service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,
  commission_start_service_minutes,service_commission_mode,active)
 select target,c.job_title_id,c.employment_type_code,c.pay_basis,c.base_pay_cents,case when j.work_category='technician' then c.service_commission_bps else 0 end,1000,case when j.work_category='technician' then c.designated_client_bonus_bps else 0 end,
  case when j.work_category='technician' then c.minimum_attendance_minutes else 0 end,case when j.work_category='technician' then c.commission_start_service_minutes else 0 end,case when j.work_category='technician' then 'ordered_tiers' else 'none' end,c.active
 from public.spa_compensation_profiles c join public.spa_job_titles j on j.id=c.job_title_id
 where j.legacy or (j.code='reception' and c.employment_type_code=any(j.allowed_employment_types));
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode)
 select target,t.metric,t.threshold_from,t.threshold_to,t.rate_bps,t.service_category_id,t.job_title_id,t.employment_type_code,t.calculation_mode
 from public.spa_payroll_commission_tiers t join public.spa_job_titles j on j.id=t.job_title_id where t.rule_version_id=source and j.legacy;
 insert into public.spa_payroll_version_profiles(rule_version_id,job_title_id,employment_type_code,pay_basis,base_pay_cents,
  service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,
  commission_start_service_minutes,service_commission_mode,active)
 select target,j.id,'owner',coalesce(c.pay_basis,'monthly'),coalesce(c.base_pay_cents,0),0,1000,0,0,0,'none',coalesce(c.active,false)
 from public.spa_job_titles j left join lateral(select * from public.spa_compensation_profiles p where p.job_title_id=j.id order by p.active desc,p.base_pay_cents desc limit 1)c on true where j.code='owner';
 insert into public.spa_payroll_version_profiles(rule_version_id,job_title_id,employment_type_code,pay_basis,base_pay_cents,
  service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,
  commission_start_service_minutes,service_commission_mode,active)
 select target,j.id,e,case when e='part_time' then 'hourly' else 'monthly' end,0,0,1000,0,0,0,'none',false
 from public.spa_job_titles j cross join unnest(j.allowed_employment_types)e where j.code='reception'
 on conflict(rule_version_id,job_title_id,employment_type_code) do nothing;
 insert into public.spa_payroll_version_profiles(rule_version_id,job_title_id,employment_type_code,pay_basis,base_pay_cents,
  service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,minimum_service_minutes,
  commission_start_service_minutes,service_commission_mode,self_sourced_commission_bps,contractor_count_scope,service_policy_status,active)
 select target,j.id,j.allowed_employment_types[1],case when j.code='pt_technician' then 'hourly' when j.code='contract_technician' then 'session' else 'monthly' end,
  case when j.code='pt_technician' then 22000 when j.code='contract_technician' then 0 else 3000000 end,
  case j.code when 'ft_probation' then 0 when 'ft_junior' then 500 when 'ft_senior_junior' then 1000 when 'ft_mid' then 1500 when 'ft_senior_mid' then 2000 when 'ft_advanced' then 2500 when 'ft_senior_advanced' then 3000 when 'pt_technician' then 500 else 3000 end,
  1000,case when j.code='contract_technician' then 0 else 500 end,case when j.code='pt_technician' then 2400 else 0 end,
  case when j.code='pt_technician' then 2400 else 0 end,case when j.code='pt_technician' then 2400 when j.code='contract_technician' then 0 else 3900 end,
  'ordered_tiers',case when j.code='contract_technician' then 5000 else 0 end,case when j.code='contract_technician' then 'lifetime' else null end,
  'confirmed',true
 from public.spa_job_titles j where not j.legacy and j.work_category='technician';
 insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode)
 select target,p.job_title_id,p.employment_type_code,'service_minutes',b.lo,b.hi,
  case when j.code='ft_probation' then 0 when b.step<0 then 0 else least(3500,p.service_commission_bps+b.step*500) end,'progressive'
 from public.spa_payroll_version_profiles p join public.spa_job_titles j on j.id=p.job_title_id
 cross join(values(0::bigint,3900::bigint,-1),(3900,4500,0),(4500,5100,1),(5100,5700,2),(5700,6300,3),(6300,6900,4),(6900,7500,5),(7500,8100,6),(8100,null,7))b(lo,hi,step)
 where p.rule_version_id=target and j.code like 'ft\_%' escape '\';
 insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode)
 select target,j.id,'part_time','service_minutes',b.lo,b.hi,b.rate,'progressive'
 from public.spa_job_titles j cross join(values(0::bigint,2400::bigint,0),(2400,3000,500),(3000,3600,1000),(3600,4200,1500),(4200,4800,2000),(4800,5400,2500),(5400,null,3000))b(lo,hi,rate) where j.code='pt_technician';
 insert into public.spa_payroll_commission_tiers(rule_version_id,job_title_id,employment_type_code,metric,threshold_from,threshold_to,rate_bps,calculation_mode)
 select target,j.id,'contractor','service_count',b.lo,b.hi,b.rate,'progressive'
 from public.spa_job_titles j cross join(values(0::bigint,100::bigint,3000),(100,null,4000))b(lo,hi,rate) where j.code='contract_technician';
 update public.spa_staff s set employment_type_code='owner' from public.spa_job_titles j where s.job_title_id=j.id and j.code='owner';
 perform spa_private.audit('payroll.ordered_policy_created',target::text,jsonb_build_object('source_rule',source,'version_no',next_no,'legacy_rank_mapping_required',true));
end $$;

alter function spa_private.payroll_preview(date,date,uuid) rename to payroll_preview_legacy_20261010;
create or replace function spa_private.payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions; profile public.spa_payroll_version_profiles; title public.spa_job_titles;
 legacy_rows jsonb; row jsonb; result jsonb:='[]'; lines jsonb; base bigint; service bigint; product bigint; designated bigint; overtime bigint; unpriced bigint;
 overtime_hourly numeric; total bigint; configured boolean; ready boolean; warning text; work bigint; service_minutes bigint; eligibility boolean; qualification_work bigint; qualification_service bigint; source_totals jsonb; designated_count bigint; designated_sales bigint;
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
  ready:=configured and not title.legacy and profile.service_policy_status='confirmed';
  warning:=case when title.legacy then '舊職稱待店主確認新職級；目前金額僅供核對，不可正式結算' when not configured then '職稱薪資未設定／未啟用' when profile.service_policy_status<>'confirmed' then '服務抽成規則待確認' when work<profile.minimum_attendance_minutes then '核准出勤未達服務抽成門檻' when service_minutes<profile.minimum_service_minutes then '服務時數未達抽成門檻' else '' end;
  lines:=case when title.legacy then '[]'::jsonb else spa_private.payroll_ordered_commissions((row->>'staff_id')::uuid,p_from,p_to,version.id) end;
  source_totals:=spa_private.payroll_source_totals(spa_private.payroll_source_records((row->>'staff_id')::uuid,p_from,p_to));
  designated_count:=(source_totals->>'designated_clients')::bigint; designated_sales:=(source_totals->>'designated_service_sales_cents')::bigint;
  select coalesce(max((x->>'qualification_work_minutes')::bigint),work),coalesce(max((x->>'qualification_service_minutes')::bigint),service_minutes) into qualification_work,qualification_service from jsonb_array_elements(lines)x;
  eligibility:=ready and (title.work_category<>'technician' or case when jsonb_array_length(lines)>0 then not exists(select 1 from jsonb_array_elements(lines)x where not (x->>'eligible')::boolean) else qualification_work>=profile.minimum_attendance_minutes and case when profile.employment_type_code='part_time' then qualification_service>profile.minimum_service_minutes else qualification_service>=profile.minimum_service_minutes end end);
  warning:=case when title.legacy then '舊職稱待店主確認新職級；目前金額僅供核對，不可正式結算' when not configured then '職稱薪資未設定／未啟用' when profile.service_policy_status<>'confirmed' then '服務抽成規則待確認' when not eligibility then '部分月份核准出勤／服務時數未達抽成門檻' else '' end;
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
  result:=result||jsonb_build_array(row||jsonb_build_object('work_category',title.work_category,'job_title_code',title.code,'classification_pending',title.legacy,
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

create or replace function spa_private.staff_classification_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare title public.spa_job_titles;
begin
 select * into title from public.spa_job_titles where id=new.job_title_id;
 if title.work_category<>'technician' then new.is_bookable:=false; end if;
 if tg_op='UPDATE' and new.job_title_id is not distinct from old.job_title_id and new.employment_type_code is not distinct from old.employment_type_code then return new; end if;
 if title.id is null or title.legacy or not title.active or title.archived_at is not null then raise exception 'JOB_CLASSIFICATION_REQUIRED'; end if;
 if not coalesce(new.employment_type_code=any(title.allowed_employment_types),false) then raise exception 'JOB_EMPLOYMENT_MISMATCH'; end if;
 if title.work_category<>'technician' then new.is_bookable:=false; end if;
 return new;
end $$;
create trigger spa_staff_classification_guard before insert or update of job_title_id,employment_type_code,is_bookable on public.spa_staff for each row execute function spa_private.staff_classification_guard();
create trigger spa_payroll_version_profile_draft_changed after insert or update or delete on public.spa_payroll_version_profiles for each statement execute function spa_private.payroll_draft_changed();

alter table public.spa_appointments add column if not exists self_sourced_client boolean not null default false;
alter table public.spa_checkouts add column if not exists self_sourced_client_snapshot boolean not null default false;
alter table public.spa_order_items
 add column if not exists self_sourced_client_snapshot boolean not null default false,
 add column if not exists designation_explicit boolean not null default false;

create or replace function public.spa_compensation_profile_save_v3(p_rule uuid,p_payload jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare title public.spa_job_titles; employment text; profile public.spa_payroll_version_profiles; old jsonb; version public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726099);
 if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'INVALID_INPUT'; end if;
 select * into version from public.spa_payroll_rule_versions where id=p_rule for update;
 if version.id is null or version.calculation_engine<>'ordered_v2' then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 if version.status='archived' then raise exception 'PAYROLL_RULE_ARCHIVED'; end if;
 select * into title from public.spa_job_titles where id=nullif(p_payload->>'job_title_id','')::uuid;
 employment:=p_payload->>'employment_type_code';
 if title.id is null or title.legacy or not title.active or not coalesce(employment=any(title.allowed_employment_types),false) then raise exception 'JOB_EMPLOYMENT_MISMATCH'; end if;
 profile:=jsonb_populate_record(null::public.spa_payroll_version_profiles,p_payload);
 if profile.pay_basis is null or profile.base_pay_cents is null or profile.service_commission_bps is null or profile.product_commission_bps is null or profile.designated_client_bonus_bps is null or profile.minimum_attendance_minutes is null or profile.minimum_service_minutes is null or profile.commission_start_service_minutes is null or profile.service_commission_mode is null or profile.self_sourced_commission_bps is null or profile.service_policy_status is null or profile.active is null then raise exception 'INVALID_INPUT'; end if;
 if title.work_category<>'technician' and (profile.service_commission_bps<>0 or profile.designated_client_bonus_bps<>0 or profile.self_sourced_commission_bps<>0 or profile.service_commission_mode<>'none') then raise exception 'SERVICE_COMMISSION_TECHNICIAN_ONLY'; end if;
 if employment='contractor' and (profile.base_pay_cents<>0 or profile.pay_basis<>'session') then raise exception 'CONTRACTOR_BASE_NOT_ALLOWED'; end if;
 if employment<>'contractor' and profile.self_sourced_commission_bps<>0 then raise exception 'SELF_SOURCED_CONTRACTOR_ONLY'; end if;
 if employment='contractor' and profile.service_policy_status='confirmed' and profile.contractor_count_scope is null then raise exception 'CONTRACTOR_SCOPE_REQUIRED'; end if;
 select to_jsonb(c) into old from public.spa_payroll_version_profiles c where c.rule_version_id=p_rule and c.job_title_id=title.id and c.employment_type_code=employment;
 insert into public.spa_payroll_version_profiles(rule_version_id,job_title_id,employment_type_code,pay_basis,base_pay_cents,
  service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,minimum_service_minutes,
  commission_start_service_minutes,service_commission_mode,self_sourced_commission_bps,contractor_count_scope,service_policy_status,active,updated_by,updated_at)
 values(p_rule,title.id,employment,profile.pay_basis,profile.base_pay_cents,profile.service_commission_bps,profile.product_commission_bps,
  profile.designated_client_bonus_bps,profile.minimum_attendance_minutes,profile.minimum_service_minutes,profile.commission_start_service_minutes,
  profile.service_commission_mode,profile.self_sourced_commission_bps,profile.contractor_count_scope,profile.service_policy_status,profile.active,auth.uid(),now())
 on conflict(rule_version_id,job_title_id,employment_type_code) do update set pay_basis=excluded.pay_basis,base_pay_cents=excluded.base_pay_cents,
  service_commission_bps=excluded.service_commission_bps,product_commission_bps=excluded.product_commission_bps,designated_client_bonus_bps=excluded.designated_client_bonus_bps,
  minimum_attendance_minutes=excluded.minimum_attendance_minutes,minimum_service_minutes=excluded.minimum_service_minutes,commission_start_service_minutes=excluded.commission_start_service_minutes,
  service_commission_mode=excluded.service_commission_mode,self_sourced_commission_bps=excluded.self_sourced_commission_bps,contractor_count_scope=excluded.contractor_count_scope,
  service_policy_status=excluded.service_policy_status,active=excluded.active,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 perform spa_private.audit('payroll.version_profile_saved',p_rule::text||':'||title.id::text||':'||employment,jsonb_build_object('old',old,'new',p_payload));
end $$;

-- The rate at sale time is immutable. Editing a future product percentage must
-- not silently rewrite an already sold item or a saved payroll packet.
create or replace function spa_private.payroll_sale_snapshot() returns trigger
language plpgsql security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions; staff public.spa_staff;
begin
 if tg_table_name='spa_order_items' then
  new.duration_minutes_snapshot:=case when new.item_type='service' then (select duration_minutes from public.spa_services where id=new.service_id) else 0 end;
  if not new.designation_explicit then new.designated_client_snapshot:=coalesce(new.item_type='service' and new.staff_id=(select c.preferred_staff_id from public.spa_orders o join public.spa_customers c on c.id=o.customer_id where o.id=new.order_id),false); end if;
  select * into staff from public.spa_staff where id=new.staff_id;
  select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=(now() at time zone 'Asia/Taipei')::date order by effective_from desc,version_no desc limit 1;
  if version.calculation_engine='ordered_v2' then
   select case when new.item_type='service' then c.service_commission_bps else c.product_commission_bps end into new.commission_bps_snapshot
   from public.spa_payroll_version_profiles c where c.rule_version_id=version.id and c.job_title_id=staff.job_title_id and c.employment_type_code=staff.employment_type_code;
   new.commission_bps_snapshot:=coalesce(new.commission_bps_snapshot,case when new.item_type='product' then 1000 else 0 end);
  else
   select case when new.item_type='service' then c.service_commission_bps else c.product_commission_bps end into new.commission_bps_snapshot
   from public.spa_compensation_profiles c where c.job_title_id=staff.job_title_id and c.employment_type_code=staff.employment_type_code and c.active;
   new.commission_bps_snapshot:=coalesce(new.commission_bps_snapshot,0);
  end if;
  new.net_total_cents:=new.line_total_cents;
 else
  select coalesce(a.booking_preference='designated' or (a.booking_preference='legacy' and c.preferred_staff_id=a.staff_id),false),a.self_sourced_client
  into new.designated_client_snapshot,new.self_sourced_client_snapshot from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id where a.id=new.appointment_id;
 end if;
 return new;
end $$;

-- Unit services are ordered by actual service time (appointment) or POS paid
-- time, then stable identifiers. Each month restarts the hour bands; contractors
-- may instead count the retained lifetime settled services after confirmation.
create or replace function spa_private.payroll_ordered_commissions(p_staff uuid,p_from date,p_to date,p_rule uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare profile public.spa_payroll_version_profiles; title public.spa_job_titles; chosen_metric text; units jsonb; result jsonb:='[]'; item jsonb; segments jsonb; unit_metric bigint; before_metric bigint; after_metric bigint; income bigint; amount bigint; designated bigint; eligible boolean; attendance bigint; service_minutes bigint; month_key text; month_metrics jsonb:='{}'; month_service_metrics jsonb:='{}'; before_service_minutes bigint; after_service_minutes bigint; month_facts jsonb; lifetime_count bigint:=0; band record; lo bigint; hi bigint; net_segment bigint;
begin
 select j.* into title from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=p_staff;
 select p.* into profile from public.spa_payroll_version_profiles p join public.spa_staff s on s.job_title_id=p.job_title_id and s.employment_type_code=p.employment_type_code where p.rule_version_id=p_rule and s.id=p_staff;
 if profile.job_title_id is null then return result; end if;
 select metric into chosen_metric from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric in ('service_minutes','service_count','service_sales_cents') order by case metric when 'service_minutes' then 1 when 'service_count' then 2 else 3 end limit 1;
 chosen_metric:=coalesce(chosen_metric,'service_minutes');
 select coalesce(jsonb_agg(to_jsonb(q) order by event_time,source_kind,source_id,unit_index),'[]') into units from (
  select 'appointment'::text source_kind,a.id source_id,a.reference,a.business_date date,a.starts_at event_time,1 unit_index,1 quantity,a.duration_minutes_snapshot duration_minutes,
   greatest(0,ch.revenue_cents-a.tea_cents)::bigint net_cents,ch.designated_client_snapshot designated,ch.self_sourced_client_snapshot self_sourced
  from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null
  where a.staff_id=p_staff and a.status='completed' and a.business_date<=p_to
   and (profile.contractor_count_scope='lifetime' or a.business_date>=date_trunc('month',p_from::timestamp)::date)
  union all
  select 'pos_service',i.id,o.reference,(o.paid_at at time zone 'Asia/Taipei')::date,o.paid_at,n,1,i.duration_minutes_snapshot,
   (floor(i.net_total_cents*n::numeric/i.quantity)-floor(i.net_total_cents*(n-1)::numeric/i.quantity))::bigint,i.designated_client_snapshot,i.self_sourced_client_snapshot
  from public.spa_order_items i join public.spa_orders o on o.id=i.order_id cross join lateral generate_series(1,i.quantity)n
  where i.staff_id=p_staff and i.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date<=p_to
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


create or replace function spa_private.payroll_input_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare old_day date; new_day date;
begin
 perform pg_advisory_xact_lock(726099);
 if tg_op='UPDATE' then
  if tg_table_name='spa_appointments' then
   if new.staff_id is not distinct from old.staff_id and new.business_date is not distinct from old.business_date and new.status is not distinct from old.status and new.duration_minutes_snapshot is not distinct from old.duration_minutes_snapshot and new.price_cents is not distinct from old.price_cents and new.tea_cents is not distinct from old.tea_cents and new.customer_id is not distinct from old.customer_id and new.booking_preference is not distinct from old.booking_preference and new.self_sourced_client is not distinct from old.self_sourced_client then return new; end if;
  elsif tg_table_name='spa_orders' then
   if new.status is not distinct from old.status and new.paid_at is not distinct from old.paid_at and new.total_cents is not distinct from old.total_cents and new.discount_cents is not distinct from old.discount_cents and new.subtotal_cents is not distinct from old.subtotal_cents and new.customer_id is not distinct from old.customer_id then return new; end if;
  end if;
 end if;
 if tg_op<>'INSERT' then
  if tg_table_name='spa_payroll_adjustments' then old_day:=old.period_start;
  elsif tg_table_name='spa_overtime_entries' then old_day:=old.work_date;
  elsif tg_table_name='spa_appointments' then old_day:=old.business_date;
  elsif tg_table_name='spa_orders' then if old.status='paid' then old_day:=(old.paid_at at time zone 'Asia/Taipei')::date; end if;
  elsif tg_table_name='spa_order_items' then select (paid_at at time zone 'Asia/Taipei')::date into old_day from public.spa_orders where id=old.order_id and status='paid';
  else select business_date into old_day from public.spa_appointments where id=old.appointment_id; end if;
 end if;
 if tg_op<>'DELETE' then
  if tg_table_name='spa_payroll_adjustments' then new_day:=new.period_start;
  elsif tg_table_name='spa_overtime_entries' then new_day:=new.work_date;
  elsif tg_table_name='spa_appointments' then new_day:=new.business_date;
  elsif tg_table_name='spa_orders' then if new.status='paid' then new_day:=(new.paid_at at time zone 'Asia/Taipei')::date; end if;
  elsif tg_table_name='spa_order_items' then select (paid_at at time zone 'Asia/Taipei')::date into new_day from public.spa_orders where id=new.order_id and status='paid';
  else select business_date into new_day from public.spa_appointments where id=new.appointment_id; end if;
 end if;
 if exists(select 1 from public.spa_payroll_runs r where r.status='finalized' and (old_day between r.period_start and r.period_end or new_day between r.period_start and r.period_end)) then raise exception 'PAYROLL_LOCKED'; end if;
 update public.spa_payroll_runs r set needs_recalculation=true where r.status='draft' and (old_day between r.period_start and r.period_end or new_day between r.period_start and r.period_end);
 if tg_op='DELETE' then return old; end if; return new;
end $$;

create or replace function public.spa_pos_checkout(p_request uuid,p_customer uuid,p_items jsonb,p_discount bigint,p_method text,p_note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result public.spa_orders; item jsonb; product public.spa_products; service public.spa_services; qty int; subtotal bigint:=0; line bigint; staff uuid; commission bigint; kind text; item_id uuid; rate int;
begin
 perform spa_private.require_permission('pos.use');
 perform pg_advisory_xact_lock(726001);
 if p_request is null or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>100 or p_discount is null or p_discount<0 or p_method is null or p_method not in ('cash','card','transfer') then raise exception 'INVALID_INPUT'; end if;
 select * into result from public.spa_orders where request_id=p_request;
 if found then return to_jsonb(result); end if;
 perform pg_advisory_xact_lock(726006); perform pg_advisory_xact_lock(726099);
 select * into result from public.spa_orders where request_id=p_request;
 if found then return to_jsonb(result); end if;
 if p_customer is not null and not exists(select 1 from public.spa_customers where id=p_customer and archived_at is null) then raise exception 'INVALID_CUSTOMER'; end if;
 insert into public.spa_orders(request_id,customer_id,created_by,note) values(p_request,p_customer,auth.uid(),coalesce(p_note,'')) returning * into result;
 for item in select * from jsonb_array_elements(p_items) loop
  qty:=coalesce((item->>'quantity')::int,0); staff:=nullif(item->>'staff_id','')::uuid;
  kind:=coalesce(nullif(item->>'item_type',''),case when item ? 'service_id' then 'service' else 'product' end);
  item_id:=coalesce(nullif(item->>'item_id',''),nullif(item->>'product_id',''),nullif(item->>'service_id',''))::uuid;
  if qty<=0 or qty>99 or kind not in ('product','service') then raise exception 'INVALID_ITEM'; end if;
  if staff is null then raise exception 'SALE_STAFF_REQUIRED'; end if;
  if coalesce((item->>'self_sourced_client')::boolean,false) and (kind<>'service' or not exists(select 1 from public.spa_staff where id=staff and employment_type_code='contractor')) then raise exception 'SELF_SOURCED_CONTRACTOR_ONLY'; end if;
  if staff is not null and not exists(select 1 from public.spa_staff where id=staff and active and employment_status='active' and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
  if kind='product' then
   select * into product from public.spa_products where id=item_id and status='active' for update;
   if not found then raise exception 'INVALID_PRODUCT'; end if;
   if not exists(select 1 from public.spa_product_categories c where c.id=product.category_id and c.active and c.archived_at is null) then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
   if coalesce((select sum(delta) from public.spa_inventory_entries where product_id=product.id),0)<qty then raise exception 'INSUFFICIENT_INVENTORY'; end if;
   line:=product.price_cents*qty; subtotal:=subtotal+line;
   select coalesce(c.product_commission_bps,0) into rate from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=staff;
   commission:=case when staff is null then 0 else round(line*coalesce(rate,0)/10000.0)::bigint end;
   insert into public.spa_order_items(order_id,product_id,item_type,name_snapshot,sku_snapshot,unit_price_cents,cost_snapshot_cents,quantity,line_total_cents,staff_id,commission_cents)
   values(result.id,product.id,'product',product.name,product.sku,product.price_cents,product.cost_cents,qty,line,staff,commission);
   insert into public.spa_inventory_entries(product_id,delta,reason,reference_type,reference_id,created_by) values(product.id,-qty,'POS 銷售 '||result.reference,'order',result.id,auth.uid());
  else
   if staff is null then raise exception 'SERVICE_STAFF_REQUIRED'; end if;
   if not exists(select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=staff and j.work_category='technician') then raise exception 'SERVICE_COMMISSION_TECHNICIAN_ONLY'; end if;
   select * into service from public.spa_services where id=item_id and active and status='active';
   if not found then raise exception 'INVALID_SERVICE'; end if;
   if not exists(select 1 from public.spa_staff_services where staff_id=staff and service_id=service.id and enabled) then raise exception 'STAFF_SKILL_REQUIRED'; end if;
   line:=service.price_cents*qty; subtotal:=subtotal+line;
   select coalesce(c.service_commission_bps,0) into rate from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=staff;
   commission:=round(line*coalesce(rate,0)/10000.0)::bigint;
   insert into public.spa_order_items(order_id,service_id,item_type,name_snapshot,unit_price_cents,quantity,line_total_cents,staff_id,commission_cents,designation_explicit,designated_client_snapshot,self_sourced_client_snapshot)
   values(result.id,service.id,'service',service.name,service.price_cents,qty,line,staff,commission,item ? 'designated_client',coalesce((item->>'designated_client')::boolean,false),coalesce((item->>'self_sourced_client')::boolean,false));
  end if;
 end loop;
 if p_discount>subtotal then raise exception 'INVALID_INPUT'; end if;
 update public.spa_orders set subtotal_cents=subtotal,discount_cents=p_discount,total_cents=subtotal-p_discount,status='paid',method=p_method,paid_at=now() where id=result.id returning * into result;
 if result.total_cents>0 then insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,result.total_cents,'pos',p_method,result.reference,auth.uid()); end if;
 perform spa_private.audit('order.paid',result.id::text,jsonb_build_object('reference',result.reference,'total_cents',result.total_cents,'items',jsonb_array_length(p_items))); return to_jsonb(result);
end $$;

create or replace function public.spa_appointment_commission_flags(p_id uuid,p_self_sourced boolean,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare appointment public.spa_appointments;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 if p_self_sourced is null or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 select * into appointment from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_self_sourced and not exists(select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=appointment.staff_id and s.employment_type_code='contractor' and j.work_category='technician') then raise exception 'SELF_SOURCED_CONTRACTOR_ONLY'; end if;
 update public.spa_appointments set self_sourced_client=p_self_sourced where id=p_id;
 update public.spa_checkouts set self_sourced_client_snapshot=p_self_sourced where appointment_id=p_id;
 perform spa_private.audit('appointment.commission_flags',p_id::text,jsonb_build_object('old_self_sourced',appointment.self_sourced_client,'self_sourced',p_self_sourced,'reason',btrim(p_reason)));
end $$;

alter function public.spa_payroll_admin(date,date,uuid) set schema spa_private;
alter function spa_private.spa_payroll_admin(date,date,uuid) rename to payroll_admin_legacy_20261010;
create or replace function public.spa_payroll_admin(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; version public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.view');
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 result:=spa_private.payroll_admin_legacy_20261010(p_from,p_to,version.id);
 if version.calculation_engine='ordered_v2' then
  result:=result||jsonb_build_object('compensation_profiles',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('job_title_name',j.name,'job_title_code',j.code,'work_category',j.work_category,'legacy',j.legacy,'employment_type_name',e.name) order by j.display_order,e.display_order)
   from public.spa_payroll_version_profiles p join public.spa_job_titles j on j.id=p.job_title_id join public.spa_employment_types e on e.code=p.employment_type_code where p.rule_version_id=version.id),'[]'));
 end if;
 return result||jsonb_build_object('selected_rule_id',version.id,'calculation_engine',version.calculation_engine,
  'unattributed_product_lines',(select count(*) from public.spa_order_items i join public.spa_orders o on o.id=i.order_id where i.item_type='product' and i.staff_id is null and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to));
end $$;

create or replace function public.spa_payroll_rule_create(p_name text,p_effective date,p_divisor int,p_include_commission boolean,p_monthly_limit int,p_agreed_limit int,p_quarter_limit int) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid; source public.spa_payroll_rule_versions; next_no int;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726099);
 if length(btrim(coalesce(p_name,''))) not between 1 and 120 or p_effective is null or p_divisor is null or p_divisor<=0 or p_monthly_limit is null or p_monthly_limit<=0 or p_agreed_limit is null or p_agreed_limit<p_monthly_limit or p_quarter_limit is null or p_quarter_limit<p_agreed_limit or p_include_commission is null then raise exception 'INVALID_INPUT'; end if;
 if p_effective>(now() at time zone 'Asia/Taipei')::date then raise exception 'FUTURE_PAYROLL_ACTIVATION_NOT_SUPPORTED'; end if;
 select * into source from public.spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1;
 select coalesce(max(version_no),0)+1 into next_no from public.spa_payroll_rule_versions;
 update public.spa_payroll_rule_versions set status='archived' where status='active';
 insert into public.spa_payroll_rule_versions(version_no,name,effective_from,status,hourly_divisor,include_regular_commission,monthly_overtime_limit_minutes,agreed_monthly_limit_minutes,quarterly_overtime_limit_minutes,created_by,calculation_engine)
 values(next_no,btrim(p_name),p_effective,'active',p_divisor,p_include_commission,p_monthly_limit,p_agreed_limit,p_quarter_limit,auth.uid(),coalesce(source.calculation_engine,'ordered_v2')) returning id into result;
 insert into public.spa_payroll_overtime_rates select result,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from public.spa_payroll_overtime_rates where rule_version_id=source.id;
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode)
 select result,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode from public.spa_payroll_commission_tiers where rule_version_id=source.id;
 insert into public.spa_payroll_version_profiles select result,job_title_id,employment_type_code,pay_basis,base_pay_cents,service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,minimum_service_minutes,commission_start_service_minutes,service_commission_mode,self_sourced_commission_bps,contractor_count_scope,service_policy_status,active,auth.uid(),now() from public.spa_payroll_version_profiles where rule_version_id=source.id;
 perform spa_private.audit('payroll.rule_created',result::text,jsonb_build_object('version',next_no,'source',source.id,'calculation_engine',source.calculation_engine)); return result;
end $$;

create or replace function public.spa_payroll_rule_activate(p_rule uuid) returns void
language plpgsql security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726099);
 select * into version from public.spa_payroll_rule_versions where id=p_rule for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if version.effective_from>(now() at time zone 'Asia/Taipei')::date then raise exception 'FUTURE_PAYROLL_ACTIVATION_NOT_SUPPORTED'; end if;
 if version.calculation_engine='ordered_v2' and not exists(select 1 from public.spa_payroll_version_profiles where rule_version_id=p_rule) then raise exception 'PAYROLL_COMPENSATION_REQUIRED'; end if;
 update public.spa_payroll_rule_versions set status=case when id=p_rule then 'active' else 'archived' end;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft';
 perform spa_private.audit('payroll.rule_activated',p_rule::text,jsonb_build_object('version',version.version_no,'calculation_engine',version.calculation_engine));
end $$;

alter function public.spa_payroll_run_save(date,date,uuid,boolean) set schema spa_private;
alter function spa_private.spa_payroll_run_save(date,date,uuid,boolean) rename to payroll_run_save_legacy_20261010;
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
  if exists(select 1 from jsonb_array_elements(preview)x where not coalesce((x->>'commission_policy_ready')::boolean,false) and coalesce((x->>'compensation_configured')::boolean,false)) then raise exception 'PAYROLL_POLICY_CONFIRMATION_REQUIRED'; end if;
 end if;
 return spa_private.payroll_run_save_legacy_20261010(p_from,p_to,version.id,p_finalize);
end $$;

alter function spa_private.payroll_rule_reference(uuid,jsonb) rename to payroll_rule_reference_legacy_20261010;
create or replace function spa_private.payroll_rule_reference(p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.payroll_rule_reference_legacy_20261010(p_rule,p_wage); version public.spa_payroll_rule_versions;
begin
 select * into version from public.spa_payroll_rule_versions where id=p_rule;
 if version.calculation_engine='ordered_v2' then
  result:=result||jsonb_build_object('profile',(result->'profile')||jsonb_build_object('work_category',p_wage->'work_category','job_title_code',p_wage->'job_title_code',
   'minimum_service_minutes',p_wage->'minimum_service_minutes','service_commission_mode',p_wage->'service_commission_mode','self_sourced_commission_bps',p_wage->'self_sourced_commission_bps',
   'contractor_count_scope',p_wage->'contractor_count_scope','service_policy_status',p_wage->'service_policy_status','calculation_engine','ordered_v2','classification_pending',p_wage->'classification_pending'));
 end if;
 return result;
end $$;

create or replace function spa_private.payroll_source_packet(p_staff uuid,p_from date,p_to date,p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare records jsonb:=spa_private.payroll_source_records(p_staff,p_from,p_to); totals jsonb; details jsonb; version public.spa_payroll_rule_versions;
begin
 totals:=spa_private.payroll_source_totals(records);
 select * into version from public.spa_payroll_rule_versions where id=p_rule;
 if version.calculation_engine='ordered_v2' and not coalesce((p_wage->>'classification_pending')::boolean,true) then
  details:=spa_private.payroll_ordered_commissions(p_staff,p_from,p_to,p_rule);
  records:=records||jsonb_build_object('commission_details',details);
  totals:=totals||jsonb_build_object('service_commission_cents',coalesce((select sum((x->>'service_commission_cents')::bigint) from jsonb_array_elements(details)x),0),
   'designated_bonus_cents',coalesce((select sum((x->>'designated_bonus_cents')::bigint) from jsonb_array_elements(details)x),0)+coalesce((totals->>'manual_designated_bonus_cents')::bigint,0),
   'product_commission_cents',coalesce((select sum((x->>'snapshot_commission_cents')::bigint) from jsonb_array_elements(records->'products')x),0));
 end if;
 return jsonb_build_object('schema_version',case when version.calculation_engine='ordered_v2' then 2 else 1 end,'staff_id',p_staff,'from',p_from,'to',p_to,'captured_at',now(),
  'sources',records,'source_totals',totals,'rule_reference',spa_private.payroll_rule_reference(p_rule,p_wage));
end $$;

alter function spa_private.payroll_source_records(uuid,date,date) rename to payroll_source_records_before_payroll_20261010;
create or replace function spa_private.payroll_source_records(p_staff uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.payroll_source_records_before_payroll_20261010(p_staff,p_from,p_to);
begin
 return result||jsonb_build_object('products',coalesce((select jsonb_agg(x.value||jsonb_build_object('commission_bps_snapshot',i.commission_bps_snapshot) order by ord)
  from jsonb_array_elements(result->'products')with ordinality x(value,ord) join public.spa_order_items i on i.id=(x.value->>'id')::uuid),'[]'),
  'services',coalesce((select jsonb_agg(x.value||jsonb_build_object('self_sourced_client',coalesce(ch.self_sourced_client_snapshot,false),'self_sourced_client_snapshot',coalesce(ch.self_sourced_client_snapshot,false)) order by ord)
   from jsonb_array_elements(result->'services')with ordinality x(value,ord) left join public.spa_checkouts ch on ch.id=nullif(x.value->>'checkout_id','')::uuid),'[]'),
  'pos_services',coalesce((select jsonb_agg(x.value||jsonb_build_object('self_sourced_client',i.self_sourced_client_snapshot,'self_sourced_client_snapshot',i.self_sourced_client_snapshot) order by ord)
   from jsonb_array_elements(result->'pos_services')with ordinality x(value,ord) join public.spa_order_items i on i.id=(x.value->>'id')::uuid),'[]'));
end $$;

-- Additional safe function metadata follows the existing public projection;
-- no compensation, hire dates, contact records or assessment data is public.
alter function public.spa_catalog() set schema spa_private;
alter function spa_private.spa_catalog() rename to catalog_before_payroll_20261010;
create or replace function public.spa_catalog() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.catalog_before_payroll_20261010(); key text;
begin
 foreach key in array array['staff','website_staff'] loop
  result:=jsonb_set(result,array[key],coalesce((select jsonb_agg(x.value||jsonb_build_object('work_category',j.work_category,'job_title_code',j.code,'employment_type_code',s.employment_type_code,'legacy',j.legacy) order by ord)
   from jsonb_array_elements(coalesce(result->key,'[]')) with ordinality x(value,ord) join public.spa_staff s on s.id=(x.value->>'id')::uuid join public.spa_job_titles j on j.id=s.job_title_id),'[]'));
 end loop;
 return result;
end $$;
alter function public.spa_catalog_admin() set schema spa_private;
alter function spa_private.spa_catalog_admin() rename to catalog_admin_before_payroll_20261010;
create or replace function public.spa_catalog_admin() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 perform spa_private.require_permission('catalog.view'); result:=spa_private.catalog_admin_before_payroll_20261010();
 return result||jsonb_build_object('staff',coalesce((select jsonb_agg(x.value||jsonb_build_object('job_title_id',s.job_title_id,'work_category',j.work_category,'job_title_code',j.code,'employment_type_code',s.employment_type_code,'legacy',j.legacy) order by ord)
  from jsonb_array_elements(coalesce(result->'staff','[]')) with ordinality x(value,ord) join public.spa_staff s on s.id=(x.value->>'id')::uuid join public.spa_job_titles j on j.id=s.job_title_id),'[]'));
end $$;

update public.spa_staff s set is_bookable=false from public.spa_job_titles j where s.job_title_id=j.id and j.work_category<>'technician';

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
    or not exists(select 1 from public.spa_compensation_profiles c where c.job_title_id=x.job_title_id and c.employment_type_code=x.employment_type_code) and not exists(select 1 from public.spa_payroll_version_profiles c where c.rule_version_id=p_rule and c.job_title_id=x.job_title_id and c.employment_type_code=x.employment_type_code)) then raise exception 'INVALID_TIER'; end if;

 if exists(select 1 from public.spa_payroll_rule_versions where id=p_rule and calculation_engine='ordered_v2') then
  if exists(select 1 from jsonb_to_recordset(p_tiers) as x(job_title_id uuid,employment_type_code text,metric text,calculation_mode text,service_category_id uuid)
   join public.spa_job_titles j on j.id=x.job_title_id where not j.legacy and (j.work_category<>'technician' or not x.employment_type_code=any(j.allowed_employment_types) or coalesce(x.calculation_mode,'progressive')<>'progressive' or x.service_category_id is not null or x.metric not in ('service_minutes','service_count'))) then raise exception 'PAYROLL_ORDERED_TIER_UNSUPPORTED'; end if;
  if exists(with bands as (
   select x.*,row_number() over(partition by x.job_title_id,x.employment_type_code,x.metric order by threshold_from)n,
    lag(threshold_to) over(partition by x.job_title_id,x.employment_type_code,x.metric order by threshold_from)previous_end,
    lead(threshold_from) over(partition by x.job_title_id,x.employment_type_code,x.metric order by threshold_from)next_start
   from jsonb_to_recordset(p_tiers)as x(job_title_id uuid,employment_type_code text,metric text,threshold_from bigint,threshold_to bigint)
   join public.spa_job_titles j on j.id=x.job_title_id where not j.legacy
  ) select 1 from bands where (n=1 and threshold_from<>0) or (n>1 and previous_end is distinct from threshold_from) or (next_start is null and threshold_to is not null)) then raise exception 'PAYROLL_TIER_GAP'; end if;
 end if;
 perform pg_advisory_xact_lock(726005); perform pg_advisory_xact_lock(726099);
 if exists(with rows as (select value,row_number() over() n from jsonb_array_elements(p_rates)) select 1 from rows a join rows b on a.n<b.n where a.value->>'employment_type_code'=b.value->>'employment_type_code' and a.value->>'overtime_type'=b.value->>'overtime_type' and int4range((a.value->>'start_minute')::int,(a.value->>'end_minute')::int,'[)') && int4range((b.value->>'start_minute')::int,(b.value->>'end_minute')::int,'[)')) then raise exception 'PAYROLL_RATE_OVERLAP'; end if;
 if exists(with rows as (select value,row_number() over() n from jsonb_array_elements(p_tiers)) select 1 from rows a join rows b on a.n<b.n where a.value->>'job_title_id'=b.value->>'job_title_id' and a.value->>'employment_type_code'=b.value->>'employment_type_code' and a.value->>'metric'<>'product_sales_cents' and b.value->>'metric'<>'product_sales_cents' and a.value->>'metric'<>b.value->>'metric') then raise exception 'PAYROLL_TIER_METRIC_CONFLICT'; end if;
 if exists(with rows as (select value,row_number() over() n from jsonb_array_elements(p_tiers)) select 1 from rows a join rows b on a.n<b.n where a.value->>'job_title_id'=b.value->>'job_title_id' and a.value->>'employment_type_code'=b.value->>'employment_type_code' and a.value->>'metric'=b.value->>'metric' and coalesce(a.value->>'calculation_mode','progressive')<>coalesce(b.value->>'calculation_mode','progressive')) then raise exception 'PAYROLL_TIER_MODE_CONFLICT'; end if;
 if exists(with rows as (select value,row_number() over() n from jsonb_array_elements(p_tiers)) select 1 from rows a join rows b on a.n<b.n where a.value->>'job_title_id'=b.value->>'job_title_id' and a.value->>'employment_type_code'=b.value->>'employment_type_code' and a.value->>'metric'=b.value->>'metric' and int8range((a.value->>'threshold_from')::bigint,(a.value->>'threshold_to')::bigint,'[)') && int8range((b.value->>'threshold_from')::bigint,(b.value->>'threshold_to')::bigint,'[)')) then raise exception 'PAYROLL_TIER_OVERLAP'; end if;
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

create trigger spa_live_invalidation after insert or update or delete or truncate on public.spa_payroll_version_profiles
 for each statement execute function spa_private.queue_live_invalidation('payroll,settings,team','');

alter function public.spa_appointment_reassign(uuid,uuid,text) set schema spa_private;
alter function spa_private.spa_appointment_reassign(uuid,uuid,text) rename to appointment_reassign_before_payroll_20261010;
create or replace function public.spa_appointment_reassign(p_appointment uuid,p_staff uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous public.spa_appointments; result jsonb;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 if not exists(select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=p_staff and j.work_category='technician') then raise exception 'SERVICE_COMMISSION_TECHNICIAN_ONLY'; end if;
 select * into previous from public.spa_appointments where id=p_appointment for update;
 result:=spa_private.appointment_reassign_before_payroll_20261010(p_appointment,p_staff,p_reason);
 if previous.staff_id is distinct from p_staff and previous.self_sourced_client then
  update public.spa_appointments set self_sourced_client=false where id=p_appointment;
  update public.spa_checkouts set self_sourced_client_snapshot=false where appointment_id=p_appointment;
  perform spa_private.audit('appointment.self_sourced_cleared_on_reassignment',p_appointment::text,jsonb_build_object('previous_staff',previous.staff_id,'actual_staff',p_staff,'reason',p_reason));
 end if;
 return result||jsonb_build_object('self_sourced_cleared',previous.staff_id is distinct from p_staff and previous.self_sourced_client);
end $$;
alter function public.spa_compensation_profile_save_v2(uuid,text,text,bigint,int,int,int,int,int,boolean) set schema spa_private;
alter function spa_private.spa_compensation_profile_save_v2(uuid,text,text,bigint,int,int,int,int,int,boolean) rename to compensation_save_v2_before_payroll_20261010;
create or replace function public.spa_compensation_profile_save_v2(
 p_job_title uuid,p_employment_type text,p_pay_basis text,p_base_pay bigint,p_service_commission int,p_product_commission int,
 p_designated_bonus_bps int,p_minimum_attendance_minutes int,p_commission_start_service_minutes int,p_active boolean default true
) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 if exists(select 1 from public.spa_payroll_rule_versions where status='active' and calculation_engine='ordered_v2') then raise exception 'PAYROLL_VERSION_PROFILE_REQUIRED'; end if;
 perform spa_private.compensation_save_v2_before_payroll_20261010(p_job_title,p_employment_type,p_pay_basis,p_base_pay,p_service_commission,p_product_commission,p_designated_bonus_bps,p_minimum_attendance_minutes,p_commission_start_service_minutes,p_active);
end $$;
alter function public.spa_compensation_profile_save(uuid,text,text,bigint,int,int,bigint,boolean) set schema spa_private;
alter function spa_private.spa_compensation_profile_save(uuid,text,text,bigint,int,int,bigint,boolean) rename to compensation_save_before_payroll_20261010;
create or replace function public.spa_compensation_profile_save(p_job_title uuid,p_employment_type text,p_pay_basis text,p_base_pay bigint,p_service_commission int,p_product_commission int,p_designated_bonus bigint,p_active boolean default true)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 if exists(select 1 from public.spa_payroll_rule_versions where status='active' and calculation_engine='ordered_v2') then raise exception 'PAYROLL_VERSION_PROFILE_REQUIRED'; end if;
 perform spa_private.compensation_save_before_payroll_20261010(p_job_title,p_employment_type,p_pay_basis,p_base_pay,p_service_commission,p_product_commission,p_designated_bonus,p_active);
end $$;
revoke all on function spa_private.appointment_reassign_before_payroll_20261010(uuid,uuid,text),spa_private.compensation_save_v2_before_payroll_20261010(uuid,text,text,bigint,int,int,int,int,int,boolean),spa_private.compensation_save_before_payroll_20261010(uuid,text,text,bigint,int,int,bigint,boolean) from public,anon,authenticated;
revoke all on function public.spa_appointment_reassign(uuid,uuid,text),public.spa_compensation_profile_save_v2(uuid,text,text,bigint,int,int,int,int,int,boolean),public.spa_compensation_profile_save(uuid,text,text,bigint,int,int,bigint,boolean) from public,anon,authenticated;
grant execute on function public.spa_appointment_reassign(uuid,uuid,text),public.spa_compensation_profile_save_v2(uuid,text,text,bigint,int,int,int,int,int,boolean),public.spa_compensation_profile_save(uuid,text,text,bigint,int,int,bigint,boolean) to authenticated,service_role;

revoke all on function spa_private.staff_classification_guard(),spa_private.payroll_ordered_commissions(uuid,date,date,uuid),spa_private.payroll_preview_legacy_20261010(date,date,uuid),spa_private.payroll_preview(date,date,uuid),
 spa_private.payroll_admin_legacy_20261010(date,date,uuid),spa_private.payroll_run_save_legacy_20261010(date,date,uuid,boolean),spa_private.payroll_rule_reference_legacy_20261010(uuid,jsonb),spa_private.payroll_rule_reference(uuid,jsonb),
 spa_private.catalog_before_payroll_20261010(),spa_private.catalog_admin_before_payroll_20261010(),spa_private.payroll_source_records_before_payroll_20261010(uuid,date,date),spa_private.payroll_source_records(uuid,date,date) from public,anon,authenticated;
revoke all on function public.spa_compensation_profile_save_v3(uuid,jsonb),public.spa_appointment_commission_flags(uuid,boolean,text),public.spa_payroll_admin(date,date,uuid),public.spa_payroll_run_save(date,date,uuid,boolean),public.spa_payroll_rule_activate(uuid),public.spa_catalog_admin() from public,anon,authenticated;
grant execute on function public.spa_compensation_profile_save_v3(uuid,jsonb),public.spa_appointment_commission_flags(uuid,boolean,text),public.spa_payroll_admin(date,date,uuid),public.spa_payroll_run_save(date,date,uuid,boolean),public.spa_payroll_rule_activate(uuid),public.spa_catalog_admin() to authenticated,service_role;
revoke all on function public.spa_catalog() from public,anon,authenticated;
grant execute on function public.spa_catalog() to anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
