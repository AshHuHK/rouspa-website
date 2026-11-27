begin;

-- Human resources owns the job hierarchy; payroll versions retain their own
-- dated wage snapshots. Monthly part-time technicians share the six ranks.
alter table public.spa_staff add column payroll_category_code text
 check(payroll_category_code in ('01','02','03','04'));
update public.spa_job_titles set allowed_employment_types=array['full_time','part_time']
 where code in ('ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced');
update public.spa_job_titles set active=false,archived_at=coalesce(archived_at,now()) where code='ft_senior_advanced';

-- Only an explicit previous assignment or unambiguous existing job is migrated.
with assigned as (
 select distinct on(n.staff_id) n.staff_id,n.category,n.rank_no,n.passed_on,n.passed_rank_no
 from spa_private.payroll_notice_staff n join public.spa_payroll_rule_versions v on v.id=n.rule_id
 where v.status in ('active','draft') order by n.staff_id,v.effective_from desc,v.version_no desc
)
update public.spa_staff s set payroll_category_code=a.category
 from assigned a,public.spa_job_titles j where s.id=a.staff_id and j.id=s.job_title_id and j.work_category='technician';
update public.spa_staff s set payroll_category_code=case
 when s.employment_type_code='full_time' and j.code in ('ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced') then '01'
 when j.code='contract_technician' and s.employment_type_code='contractor' then '04'
 when j.code='pt_technician' and s.employment_type_code='part_time' and s.pay_basis='hourly' then '03' end
 from public.spa_job_titles j where j.id=s.job_title_id and s.payroll_category_code is null and not j.legacy;
-- Explicitly assigned monthly rank is authoritative, rather than a generic
-- 'part-time' title. No pay amount or percentage is inferred from seniority.
with assigned as (
 select distinct on(n.staff_id) n.* from spa_private.payroll_notice_staff n
 join public.spa_payroll_rule_versions v on v.id=n.rule_id
 where v.status in ('active','draft') order by n.staff_id,v.effective_from desc,v.version_no desc
)
update public.spa_staff s set job_title_id=j.id,title=j.name
 from assigned a,public.spa_job_titles j
 where s.id=a.staff_id and s.payroll_category_code in ('01','02') and
 j.code=(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'])[
 case when a.passed_on<=(now() at time zone 'Asia/Taipei')::date then a.passed_rank_no else a.rank_no end];

alter function public.spa_staff_profile_save_v2(jsonb) rename to staff_profile_save_before_hierarchy;
alter function public.staff_profile_save_before_hierarchy(jsonb) set schema spa_private;
revoke all on function spa_private.staff_profile_save_before_hierarchy(jsonb) from public,anon,authenticated;

create function public.spa_staff_profile_save_v2(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid; j public.spa_job_titles; category text; rank int; v record; existing spa_private.payroll_notice_staff;
 employment text:=p_payload->>'employment_type_code';
begin
 perform spa_private.require_permission('team.manage');
 perform pg_advisory_xact_lock(726099);
 -- Old clients may save unrelated profile fields without inventing a category.
 if not p_payload?'payroll_category_code' then return spa_private.staff_profile_save_before_hierarchy(p_payload); end if;
 select * into j from public.spa_job_titles where id=nullif(p_payload->>'job_title_id','')::uuid and active and archived_at is null and not legacy;
 if j.id is null then raise exception 'JOB_CLASSIFICATION_REQUIRED'; end if;
 category:=nullif(p_payload->>'payroll_category_code','');
 rank:=array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code);
 if j.work_category='technician' then
  if not coalesce((category='01' and employment='full_time' and rank is not null)
    or (category='02' and employment='part_time' and rank is not null)
    or (category='03' and employment='part_time' and j.code='pt_technician')
    or (category='04' and employment='contractor' and j.code='contract_technician'),false)
  then raise exception 'JOB_EMPLOYMENT_MISMATCH'; end if;
  -- Changing a published wage classification requires a new draft. The old
  -- version and already saved wage packets cannot be rewritten by an HR form.
  for v in select id from public.spa_payroll_rule_versions where status='active' and calculation_engine='notice_v1' loop
   select * into existing from spa_private.payroll_notice_staff where rule_id=v.id and staff_id=nullif(p_payload->>'id','')::uuid;
   if found and (existing.category is distinct from category or
     case when existing.passed_on<=(now() at time zone 'Asia/Taipei')::date then existing.passed_rank_no else existing.rank_no end is distinct from rank)
     and not exists(select 1 from public.spa_payroll_rule_versions where status='draft' and calculation_engine='notice_v1')
   then raise exception 'PAYROLL_CLASSIFICATION_REQUIRES_DRAFT'; end if;
  end loop;
 elsif category is not null then raise exception 'JOB_EMPLOYMENT_MISMATCH';
 end if;
 result:=spa_private.staff_profile_save_before_hierarchy(p_payload);
 update public.spa_staff set payroll_category_code=category,
  pay_basis=case category when '01' then 'monthly' when '02' then 'monthly' when '03' then 'hourly' when '04' then 'session' else pay_basis end
 where id=result;
 for v in select id from public.spa_payroll_rule_versions where status='draft' and calculation_engine='notice_v1' loop
  if j.work_category<>'technician' then
   delete from spa_private.payroll_notice_staff where rule_id=v.id and staff_id=result;
  else
   insert into spa_private.payroll_notice_staff(rule_id,staff_id,category,rank_no,contract_from)
   values(v.id,result,category,rank,case when category='04' then nullif(p_payload->>'contract_started_on','')::date end)
   on conflict(rule_id,staff_id) do update set category=excluded.category,rank_no=excluded.rank_no,
    start_bps=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.rank_no is not distinct from excluded.rank_no then payroll_notice_staff.start_bps end,
    contract_from=excluded.contract_from,
    credited_from=case when excluded.category='04' and payroll_notice_staff.contract_from=excluded.contract_from then payroll_notice_staff.credited_from end,
    passed_on=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.rank_no is not distinct from excluded.rank_no then payroll_notice_staff.passed_on end,
    passed_rank_no=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.rank_no is not distinct from excluded.rank_no then payroll_notice_staff.passed_rank_no end;
  end if;
 end loop;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft';
 perform spa_private.audit('staff.classification_saved',result::text,jsonb_build_object('category',category,'rank',rank));
 return result;
end $$;

-- Notice dropdowns exclude archived demo identities, while genuine departed
-- staff retain wage history. Counter and owner roles are not technicians.
create or replace function public.spa_payroll_notice_get(p_rule uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return (select to_jsonb(n)||jsonb_build_object(
  'ranks',(select jsonb_agg(to_jsonb(r)-'rule_id' order by rank_no) from spa_private.payroll_notice_ranks r where r.rule_id=p_rule),
  'technician_ids',coalesce((select jsonb_agg(s.id) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where j.work_category='technician' and s.archived_at is null),'[]'),
  'assignments',coalesce((select jsonb_agg(to_jsonb(a)-'rule_id' order by a.staff_id) from spa_private.payroll_notice_staff a
   join public.spa_staff s on s.id=a.staff_id join public.spa_job_titles j on j.id=s.job_title_id
   where a.rule_id=p_rule and s.archived_at is null and j.work_category='technician'),'[]'))
 from spa_private.payroll_notices n where n.rule_id=p_rule);
end $$;

alter function public.spa_payroll_notice_assign(uuid,uuid,jsonb) rename to payroll_notice_assign_before_hierarchy;
alter function public.payroll_notice_assign_before_hierarchy(uuid,uuid,jsonb) set schema spa_private;
revoke all on function spa_private.payroll_notice_assign_before_hierarchy(uuid,uuid,jsonb) from public,anon,authenticated;
create function public.spa_payroll_notice_assign(p_rule uuid,p_staff uuid,p_assignment jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare s public.spa_staff; j public.spa_job_titles; rank int;
begin
 perform spa_private.require_permission('payroll.manage');
 select * into s from public.spa_staff where id=p_staff and archived_at is null;
 if not found then raise exception 'NOT_FOUND'; end if;
 select * into j from public.spa_job_titles where id=s.job_title_id;
 rank:=array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code);
 if s.payroll_category_code is not null and ((p_assignment->>'category') is distinct from s.payroll_category_code or
  (s.payroll_category_code in ('01','02') and (p_assignment->>'rank_no')::int is distinct from rank))
 then raise exception 'PAYROLL_CLASSIFICATION_MISMATCH'; end if;
 perform spa_private.payroll_notice_assign_before_hierarchy(p_rule,p_staff,p_assignment);
end $$;

alter function public.spa_payroll_notice_pass(uuid,uuid,date,int) rename to payroll_notice_pass_before_hierarchy;
alter function public.payroll_notice_pass_before_hierarchy(uuid,uuid,date,int) set schema spa_private;
revoke all on function spa_private.payroll_notice_pass_before_hierarchy(uuid,uuid,date,int) from public,anon,authenticated;
create function public.spa_payroll_notice_pass(p_rule uuid,p_staff uuid,p_on date,p_rank int) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.payroll_notice_pass_before_hierarchy(p_rule,p_staff,p_on,p_rank);
 update public.spa_staff s set job_title_id=j.id,title=j.name
 from public.spa_job_titles j where s.id=p_staff and s.payroll_category_code in ('01','02')
  and j.code=(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'])[p_rank];
end $$;
revoke all on function public.spa_payroll_notice_pass(uuid,uuid,date,int) from public,anon,authenticated;
grant execute on function public.spa_payroll_notice_pass(uuid,uuid,date,int) to authenticated,service_role;

-- Newly created drafts start from HR classifications rather than copied demo
-- assignments. Archived identities and non-technicians cannot enter new policy.
alter function public.spa_payroll_notice_setup(date) rename to payroll_notice_setup_before_hierarchy;
alter function public.payroll_notice_setup_before_hierarchy(date) set schema spa_private;
revoke all on function spa_private.payroll_notice_setup_before_hierarchy(date) from public,anon,authenticated;
create function public.spa_payroll_notice_setup(p_effective date) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 result:=spa_private.payroll_notice_setup_before_hierarchy(p_effective);
 delete from spa_private.payroll_notice_staff a where a.rule_id=result and not exists(
  select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
  where s.id=a.staff_id and s.archived_at is null and j.work_category='technician');
 insert into spa_private.payroll_notice_staff(rule_id,staff_id,category,rank_no,contract_from)
 select result,s.id,s.payroll_category_code,
  case when s.payroll_category_code in ('01','02') then array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code) end,
  case when s.payroll_category_code='04' then s.contract_started_on end
 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
 where s.archived_at is null and j.work_category='technician' and s.payroll_category_code is not null
  and (s.payroll_category_code<>'04' or s.contract_started_on is not null)
 on conflict(rule_id,staff_id) do update set category=excluded.category,rank_no=excluded.rank_no,contract_from=excluded.contract_from,
  start_bps=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.rank_no is not distinct from excluded.rank_no then payroll_notice_staff.start_bps end,
  credited_from=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.contract_from=excluded.contract_from then payroll_notice_staff.credited_from end,
  passed_on=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.rank_no is not distinct from excluded.rank_no then payroll_notice_staff.passed_on end,
  passed_rank_no=case when payroll_notice_staff.category=excluded.category and payroll_notice_staff.rank_no is not distinct from excluded.rank_no then payroll_notice_staff.passed_rank_no end;
 return result;
end $$;
revoke all on function public.spa_payroll_notice_setup(date) from public,anon,authenticated;
grant execute on function public.spa_payroll_notice_setup(date) to authenticated,service_role;

-- Repair only editable drafts; published and finalized historical facts remain.
delete from spa_private.payroll_notice_staff a using public.spa_payroll_rule_versions v
 where v.id=a.rule_id and v.status='draft' and not exists(
  select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
  where s.id=a.staff_id and s.archived_at is null and j.work_category='technician');

alter function public.spa_payroll_admin(date,date,uuid) rename to payroll_admin_before_hierarchy;
alter function public.payroll_admin_before_hierarchy(date,date,uuid) set schema spa_private;
revoke all on function spa_private.payroll_admin_before_hierarchy(date,date,uuid) from public,anon,authenticated;
create function public.spa_payroll_admin(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare packet jsonb:=spa_private.payroll_admin_before_hierarchy(p_from,p_to,p_rule);
begin
 return packet||jsonb_build_object('staff',coalesce((select jsonb_agg(a.value||jsonb_build_object('job_title_code',j.code,
  'hr_rank_no',array_position(array['ft_probation','ft_junior','ft_senior_junior','ft_mid','ft_senior_mid','ft_advanced'],j.code)) order by a.ordinality)
  from jsonb_array_elements(packet->'staff') with ordinality a left join public.spa_job_titles j on j.id=(a.value->>'job_title_id')::uuid),'[]'));
end $$;
revoke all on function public.spa_payroll_admin(date,date,uuid) from public,anon,authenticated;
grant execute on function public.spa_payroll_admin(date,date,uuid) to authenticated,service_role;

-- A technician's appointment scope is enforced before JSON leaves the server,
-- including custom login roles mapped to a technician HR record.
create function spa_private.own_bookings_only() returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(spa_private.role_name()<>'owner' and (spa_private.role_name()='therapist' or exists(
  select 1 from public.spa_roles r join public.spa_staff s on s.id=r.staff_id join public.spa_job_titles j on j.id=s.job_title_id
  where r.user_id=auth.uid() and r.active and j.work_category='technician')),false)
$$;
revoke all on function spa_private.own_bookings_only() from public,anon,authenticated;

alter function public.spa_admin_bookings(date,date) rename to admin_bookings_before_own_scope;
alter function public.admin_bookings_before_own_scope(date,date) set schema spa_private;
revoke all on function spa_private.admin_bookings_before_own_scope(date,date) from public,anon,authenticated;
create function public.spa_admin_bookings(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb:=spa_private.admin_bookings_before_own_scope(p_from,p_to); viewer uuid:=spa_private.current_staff_id();
begin
 if not spa_private.own_bookings_only() then return rows; end if;
 return coalesce((select jsonb_agg(a.value order by a.ordinality) from jsonb_array_elements(rows) with ordinality a where a.value->>'staff_id'=viewer::text),'[]');
end $$;

alter function public.spa_monthly_operations(date) rename to monthly_operations_before_own_scope;
alter function public.monthly_operations_before_own_scope(date) set schema spa_private;
revoke all on function spa_private.monthly_operations_before_own_scope(date) from public,anon,authenticated;
create function public.spa_monthly_operations(p_month date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare calendar jsonb:=spa_private.monthly_operations_before_own_scope(p_month); viewer uuid:=spa_private.current_staff_id();
begin
 if not spa_private.own_bookings_only() then return calendar; end if;
 return calendar||jsonb_build_object('own_bookings_only',true,'days',(
  select jsonb_agg(d.value||jsonb_build_object('appointments',a.rows,'appointment_count',jsonb_array_length(a.rows),
   'capacity_attention_count',(select count(*) from jsonb_array_elements(a.rows) x where (x->>'capacity_exceeded')::boolean)) order by d.ordinality)
  from jsonb_array_elements(calendar->'days') with ordinality d
  cross join lateral (select coalesce(jsonb_agg(x.value order by x.ordinality),'[]') rows
   from jsonb_array_elements(d.value->'appointments') with ordinality x where x.value->>'staff_id'=viewer::text) a
 ));
end $$;

alter function public.spa_dashboard() rename to dashboard_before_own_scope;
alter function public.dashboard_before_own_scope() set schema spa_private;
revoke all on function spa_private.dashboard_before_own_scope() from public,anon,authenticated;
create function public.spa_dashboard() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare packet jsonb:=spa_private.dashboard_before_own_scope(); viewer uuid:=spa_private.current_staff_id(); today date:=(packet->>'date')::date;
begin
 if not spa_private.own_bookings_only() then return packet; end if;
 return packet||jsonb_build_object('own_bookings_only',true,
  'appointments',(select count(*) from public.spa_appointments where business_date=today and staff_id=viewer),
  'pending',(select count(*) from public.spa_appointments where business_date=today and staff_id=viewer and status='pending'),
  'completed',(select count(*) from public.spa_appointments where business_date=today and staff_id=viewer and status='completed'),
  'cancelled',(select count(*) from public.spa_appointments where business_date=today and staff_id=viewer and status in ('cancelled','no_show')),
  'capacity_attention_count',(select count(*) from public.spa_appointments a where business_date=today and staff_id=viewer and spa_private.capacity_exceeded(a.id)),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x) order by x.starts_at) from (
   select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,left(btrim(c.name),1)||'小姐' customer_name,
    s.name staff_name,spa_private.capacity_exceeded(a.id) capacity_exceeded
   from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id
   where a.business_date=today and a.staff_id=viewer and a.status not in ('cancelled','no_show') order by a.starts_at limit 8
  ) x),'[]'));

end $$;

alter function public.spa_session() rename to session_before_own_scope;
alter function public.session_before_own_scope() set schema spa_private;
revoke all on function spa_private.session_before_own_scope() from public,anon,authenticated;
create function public.spa_session() returns jsonb
language sql stable security definer set search_path='' as $$
 select spa_private.session_before_own_scope()||jsonb_build_object('own_bookings_only',spa_private.own_bookings_only())
$$;
revoke all on function public.spa_session() from public,anon,authenticated;
grant execute on function public.spa_session() to authenticated,service_role;

revoke all on function public.spa_staff_profile_save_v2(jsonb),public.spa_payroll_notice_get(uuid),public.spa_payroll_notice_assign(uuid,uuid,jsonb),public.spa_admin_bookings(date,date),public.spa_monthly_operations(date),public.spa_dashboard() from public,anon,authenticated;
grant execute on function public.spa_staff_profile_save_v2(jsonb),public.spa_payroll_notice_get(uuid),public.spa_payroll_notice_assign(uuid,uuid,jsonb),public.spa_admin_bookings(date,date),public.spa_monthly_operations(date),public.spa_dashboard() to authenticated,service_role;
notify pgrst,'reload schema';
commit;
