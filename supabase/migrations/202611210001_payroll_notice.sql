begin;

alter table public.spa_payroll_rule_versions drop constraint spa_payroll_engine_check;
alter table public.spa_payroll_rule_versions add constraint spa_payroll_engine_check
 check (calculation_engine in ('legacy_period_average','ordered_v2','notice_v1'));

create table spa_private.payroll_notices (
 rule_id uuid primary key references public.spa_payroll_rule_versions on delete cascade,
 full_time_threshold_minutes int not null default 4200 check(full_time_threshold_minutes between 0 and 30000),
 monthly_threshold_minutes int not null default 3900 check(monthly_threshold_minutes between 0 and 30000),
 hourly_threshold_minutes int not null default 2400 check(hourly_threshold_minutes between 0 and 30000),
 step_minutes int not null default 600 check(step_minutes between 1 and 6000)
);

create table spa_private.payroll_notice_ranks (
 rule_id uuid not null references spa_private.payroll_notices on delete cascade,
 rank_no int not null check(rank_no between 1 and 6),
 full_time_start_bps int not null check(full_time_start_bps in (0,500,1000,1500,2000,2500,3000)),
 monthly_start_bps int not null check(monthly_start_bps in (0,500,1000,1500,2000,2500)),
 monthly_base_cents bigint not null check(monthly_base_cents between 0 and 100000000),
 primary key(rule_id,rank_no)
);

create table spa_private.payroll_notice_staff (
 rule_id uuid not null references spa_private.payroll_notices on delete cascade,
 staff_id uuid not null references public.spa_staff,
 category text not null check(category in ('01','02','03','04')),
 rank_no int,
 start_bps int check(start_bps in (0,500,1000,1500,2000,2500,3000)),
 contract_from date,
 credited_from date,
 passed_on date,
 passed_rank_no int,
 primary key(rule_id,staff_id),
 foreign key(rule_id,rank_no) references spa_private.payroll_notice_ranks,
 foreign key(rule_id,passed_rank_no) references spa_private.payroll_notice_ranks,
 check(category<>'02' or start_bps is null or start_bps<=2500),
 check((passed_on is null and passed_rank_no is null) or (passed_on is not null and passed_rank_no is not null and passed_rank_no between 2 and 6 and category in ('01','02'))),
 check(
  (category in ('01','02') and rank_no is not null and contract_from is null and credited_from is null)
  or (category='03' and rank_no is null and start_bps is null and contract_from is null and credited_from is null)
  or (category='04' and rank_no is null and start_bps is null and contract_from is not null
      and (credited_from is null or credited_from<=contract_from))
 )
);

alter table spa_private.payroll_notices enable row level security;
alter table spa_private.payroll_notice_ranks enable row level security;
alter table spa_private.payroll_notice_staff enable row level security;
revoke all on spa_private.payroll_notices,spa_private.payroll_notice_ranks,spa_private.payroll_notice_staff from public,anon,authenticated;

-- Date and rank decisions are saved by the owner. The migration itself
-- creates no new compensation version and assigns no one to a pay category.
create function public.spa_payroll_notice_setup(p_effective date) returns uuid
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
  insert into spa_private.payroll_notice_staff(rule_id,staff_id,category,rank_no,start_bps,contract_from,credited_from,passed_on,passed_rank_no)
  select result,staff_id,category,case when passed_on<p_effective then passed_rank_no else rank_no end,
   case when passed_on<p_effective then null else start_bps end,contract_from,credited_from,
   case when passed_on>=p_effective then passed_on end,case when passed_on>=p_effective then passed_rank_no end
  from spa_private.payroll_notice_staff where rule_id=source.id;
 end if;
 insert into public.spa_payroll_overtime_rates select result,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from public.spa_payroll_overtime_rates where rule_version_id=source.id;
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode)
 select result,metric,threshold_from,threshold_to,rate_bps,service_category_id,job_title_id,employment_type_code,calculation_mode
 from public.spa_payroll_commission_tiers where rule_version_id=source.id;
 insert into public.spa_payroll_version_profiles
 select result,job_title_id,employment_type_code,pay_basis,base_pay_cents,service_commission_bps,product_commission_bps,designated_client_bonus_bps,minimum_attendance_minutes,minimum_service_minutes,commission_start_service_minutes,service_commission_mode,self_sourced_commission_bps,contractor_count_scope,service_policy_status,active,auth.uid(),now()
 from public.spa_payroll_version_profiles where rule_version_id=source.id;
 perform spa_private.audit('payroll.notice_created',result::text,jsonb_build_object('effective_from',p_effective,'source',source.id));
 return result;
end $$;

create function public.spa_payroll_notice_get(p_rule uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return (select to_jsonb(n)||jsonb_build_object(
  'ranks',(select jsonb_agg(to_jsonb(r)-'rule_id' order by rank_no) from spa_private.payroll_notice_ranks r where r.rule_id=p_rule),
  'technician_ids',coalesce((select jsonb_agg(s.id) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where j.work_category='technician'),'[]'),
  'assignments',coalesce((select jsonb_agg(to_jsonb(s)-'rule_id' order by staff_id) from spa_private.payroll_notice_staff s where s.rule_id=p_rule),'[]'))
 from spa_private.payroll_notices n where n.rule_id=p_rule);
end $$;

create function public.spa_payroll_notice_save(p_rule uuid,p_settings jsonb,p_ranks jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 if not exists(select 1 from public.spa_payroll_rule_versions where id=p_rule and status='draft' and calculation_engine='notice_v1')
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

create function public.spa_payroll_notice_assign(p_rule uuid,p_staff uuid,p_assignment jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare v public.spa_payroll_rule_versions; s public.spa_staff; category text:=nullif(p_assignment->>'category',''); contract_date date; credit_date date;
begin
 perform spa_private.require_permission('payroll.manage');
 perform pg_advisory_xact_lock(726099);
 select * into v from public.spa_payroll_rule_versions where id=p_rule and calculation_engine='notice_v1';
 if v.status is null or v.status not in ('draft','active') then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 select s1.* into s from public.spa_staff s1 join public.spa_job_titles j on j.id=s1.job_title_id
 where s1.id=p_staff and j.work_category='technician';
 if not found then raise exception 'NOT_FOUND'; end if;
 if v.status='active' and (
  category is null or v.id is distinct from (select id from public.spa_payroll_rule_versions where status='active'
   and effective_from<=(now() at time zone 'Asia/Taipei')::date order by effective_from desc,version_no desc limit 1)
  or exists(select 1 from spa_private.payroll_notice_staff where rule_id=p_rule and staff_id=p_staff)
  or exists(select 1 from public.spa_payroll_runs
   where status='finalized' and period_end>=greatest(v.effective_from,coalesce(s.hire_date,v.effective_from)))
 ) then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 if category is null then
  delete from spa_private.payroll_notice_staff where rule_id=p_rule and staff_id=p_staff;
 else
  contract_date:=nullif(p_assignment->>'contract_from','')::date;
  credit_date:=nullif(p_assignment->>'credited_from','')::date;
  if credit_date<s.hire_date then raise exception 'INVALID_INPUT'; end if;
  insert into spa_private.payroll_notice_staff(rule_id,staff_id,category,rank_no,start_bps,contract_from,credited_from)
  values(p_rule,p_staff,category,nullif(p_assignment->>'rank_no','')::int,nullif(p_assignment->>'start_bps','')::int,contract_date,credit_date)
  on conflict(rule_id,staff_id) do update set category=excluded.category,rank_no=excluded.rank_no,start_bps=excluded.start_bps,
   contract_from=excluded.contract_from,credited_from=excluded.credited_from,passed_on=null,passed_rank_no=null;
 end if;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and rule_version_id=p_rule;
 perform spa_private.audit('payroll.notice_staff_saved',p_staff::text,jsonb_build_object('version',p_rule,'category',category));
end $$;

-- A charge crossing a boundary is split in integer cents using cumulative
-- allocation, so the amounts in the segments always sum to the charge.
create function spa_private.payroll_notice_segments(
 p_before bigint,p_minutes int,p_net bigint,p_threshold int,p_step int,p_start int,p_cap int,p_zero_progresses boolean
) returns table(stage text,from_minute bigint,to_minute bigint,net_cents bigint,rate_bps int,commission_cents bigint)
language sql immutable set search_path='' as $$
 with bounds as (
  select p_before first_minute,p_before+p_minutes last_minute
 ), edges as (
  select first_minute x from bounds union select last_minute from bounds
  union select p_threshold from bounds where p_threshold>first_minute and p_threshold<last_minute
  union
  select p_threshold+n*p_step from bounds
  cross join generate_series(1,greatest(0,(p_cap-p_start)/500)) n
  where p_threshold+n*p_step>first_minute and p_threshold+n*p_step<last_minute
 ), intervals as (
  select x lo,lead(x) over(order by x) hi from edges
 ), splits as (
  select lo,hi,(floor(p_net*(hi-p_before)::numeric/p_minutes)-floor(p_net*(lo-p_before)::numeric/p_minutes))::bigint share,
   case when lo<p_threshold or (p_start=0 and not p_zero_progresses) then 0
    else least(p_cap,p_start+500*((lo-p_threshold)/p_step)::int) end rate
  from intervals where hi>lo and p_minutes>0
 )
 select case when lo<p_threshold then 'base_covered' else 'progressive' end,lo,hi,share,rate,round(share*rate/10000.0)::bigint
 from splits order by lo;
$$;

revoke all on function public.spa_payroll_notice_setup(date),public.spa_payroll_notice_get(uuid),public.spa_payroll_notice_save(uuid,jsonb,jsonb),public.spa_payroll_notice_assign(uuid,uuid,jsonb),spa_private.payroll_notice_segments(bigint,int,bigint,int,int,int,int,boolean) from public,anon,authenticated;
grant execute on function public.spa_payroll_notice_setup(date),public.spa_payroll_notice_get(uuid),public.spa_payroll_notice_save(uuid,jsonb,jsonb),public.spa_payroll_notice_assign(uuid,uuid,jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
