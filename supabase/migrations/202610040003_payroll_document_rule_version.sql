begin;

-- Preserve the prior active rule as payroll history and make the supplied
-- technician policy the active rule for new calculations. Existing finalized
-- payroll runs continue to point at their original immutable rule version.
do $$
declare
 source_rule uuid;
 target_rule uuid;
 next_version int;
begin
 if exists(select 1 from public.spa_payroll_rule_versions where name='技師薪資制度（文件版）') then
  return;
 end if;

 select id into source_rule
 from public.spa_payroll_rule_versions
 where status='active'
 order by effective_from desc,version_no desc
 limit 1;

 select coalesce(max(version_no),0)+1 into next_version from public.spa_payroll_rule_versions;
 update public.spa_payroll_rule_versions set status='archived' where status='active';

 insert into public.spa_payroll_rule_versions(
  version_no,name,effective_from,status,hourly_divisor,include_regular_commission,
  monthly_overtime_limit_minutes,agreed_monthly_limit_minutes,quarterly_overtime_limit_minutes,created_by
 )
 select next_version,'技師薪資制度（文件版）',current_date,'active',
        coalesce(v.hourly_divisor,240),coalesce(v.include_regular_commission,true),
        coalesce(v.monthly_overtime_limit_minutes,2760),coalesce(v.agreed_monthly_limit_minutes,3240),
        coalesce(v.quarterly_overtime_limit_minutes,8280),auth.uid()
 from (select 1) seed
 left join public.spa_payroll_rule_versions v on v.id=source_rule
 returning id into target_rule;

 insert into public.spa_payroll_overtime_rates(
  rule_version_id,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps
 )
 select target_rule,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps
 from public.spa_payroll_overtime_rates
 where rule_version_id=source_rule;

 -- Full-time: the first 65 service hours are included in salary. From hour 66,
 -- each ten-hour band increases by five percentage points, capped at 35%.
 insert into public.spa_payroll_commission_tiers(
  rule_version_id,job_title_id,employment_type_code,metric,
  threshold_from,threshold_to,rate_bps,calculation_mode
 )
 select target_rule,c.job_title_id,c.employment_type_code,'service_minutes',
        b.threshold_from,b.threshold_to,least(3500,p.start_rate+b.step_no*500),'progressive'
 from public.spa_compensation_profiles c
 join public.spa_job_titles j on j.id=c.job_title_id
 cross join lateral (
  select coalesce(nullif(c.service_commission_bps,0),case j.code
   when 'owner' then 3500 when 'manager' then 3500 when 'head_therapist' then 3000
   when 'senior_therapist' then 2000 else 500 end) start_rate
 ) p
 cross join (values
  (3900::bigint,4500::bigint,0),(4500,5100,1),(5100,5700,2),(5700,6300,3),
  (6300,6900,4),(6900,7500,5),(7500,8100,6),(8100,null,7)
 ) b(threshold_from,threshold_to,step_no)
 where c.employment_type_code='full_time';

 -- Part-time: 40 hours of attendance is the editable eligibility default;
 -- service-hour commission increases from 5% to 30% in ten-hour bands.
 insert into public.spa_payroll_commission_tiers(
  rule_version_id,job_title_id,employment_type_code,metric,
  threshold_from,threshold_to,rate_bps,calculation_mode
 )
 select target_rule,c.job_title_id,c.employment_type_code,'service_minutes',
        b.threshold_from,b.threshold_to,b.rate_bps,'progressive'
 from public.spa_compensation_profiles c
 cross join (values
  (2400::bigint,3000::bigint,500),(3000,3600,1000),(3600,4200,1500),
  (4200,4800,2000),(4800,5400,2500),(5400,null,3000)
 ) b(threshold_from,threshold_to,rate_bps)
 where c.employment_type_code='part_time';

 -- Contractor: the first 100 completed services use 30%; later services use
 -- 40%. The separate self-sourced/customer attribution bonus remains editable
 -- through the title profile and manual adjustment workflow.
 insert into public.spa_payroll_commission_tiers(
  rule_version_id,job_title_id,employment_type_code,metric,
  threshold_from,threshold_to,rate_bps,calculation_mode
 )
 select target_rule,c.job_title_id,c.employment_type_code,'service_count',
        b.threshold_from,b.threshold_to,b.rate_bps,'progressive'
 from public.spa_compensation_profiles c
 cross join (values (0::bigint,100::bigint,3000),(100,null,4000))
  b(threshold_from,threshold_to,rate_bps)
 where c.employment_type_code='contractor';

 perform spa_private.audit('payroll.document_rule_activated',target_rule::text,
  jsonb_build_object('source_rule',source_rule,'version_no',next_version,'policy','技師薪資制度'));
end $$;

notify pgrst,'reload schema';
commit;
