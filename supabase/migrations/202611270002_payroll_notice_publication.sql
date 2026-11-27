begin;

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

-- Publication can be approved in advance, but wages cannot be finalized
-- under a policy whose effective date has not arrived.
alter function public.spa_payroll_run_save(date,date,uuid,boolean) rename to payroll_run_save_before_scheduled_notice;
alter function public.payroll_run_save_before_scheduled_notice(date,date,uuid,boolean) set schema spa_private;
revoke all on function spa_private.payroll_run_save_before_scheduled_notice(date,date,uuid,boolean) from public,anon,authenticated;
create function public.spa_payroll_run_save(p_from date,p_to date,p_rule uuid default null,p_finalize boolean default false) returns uuid
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 if p_finalize and exists(select 1 from public.spa_payroll_rule_versions where id=coalesce(p_rule,spa_private.payroll_notice_rule_on(p_to))
  and effective_from>(now() at time zone 'Asia/Taipei')::date) then raise exception 'PAYROLL_POLICY_NOT_EFFECTIVE'; end if;
 return spa_private.payroll_run_save_before_scheduled_notice(p_from,p_to,p_rule,p_finalize);
end $$;
revoke all on function public.spa_payroll_run_save(date,date,uuid,boolean) from public,anon,authenticated;
grant execute on function public.spa_payroll_run_save(date,date,uuid,boolean) to authenticated,service_role;

revoke all on function public.spa_payroll_notice_activate(uuid) from public,anon,authenticated;
grant execute on function public.spa_payroll_notice_activate(uuid) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
