-- Owner-authorized: use the existing v8 global rules immediately for the
-- current unsettled natural month. No payroll is finalized or paid here.
begin;
select pg_advisory_xact_lock(726005);
select pg_advisory_xact_lock(726099);
create temporary table payroll_preserved_finals on commit drop as
 select id,to_jsonb(r) original from public.spa_payroll_runs r where status='finalized';
create temporary table payroll_preserved_sources on commit drop as
 select run_id,staff_id,md5(packet::text) original from public.spa_payroll_source_snapshots;
do $$
declare target uuid; first_day date:=date_trunc('month',now() at time zone 'Asia/Taipei')::date;
begin
 select id into target from public.spa_payroll_rule_versions where version_no=8 and calculation_engine='notice_v1' and status='active';
 if target is null then raise exception 'EXPECTED_V8_NOT_FOUND'; end if;
 if exists(select 1 from public.spa_payroll_runs where status='finalized' and period_end>=first_day)
 then raise exception 'CURRENT_MONTH_ALREADY_FINALIZED'; end if;
 update public.spa_payroll_rule_versions set status='archived' where calculation_engine='notice_v1' and status='active' and id<>target;
 update public.spa_payroll_rule_versions set effective_from=first_day where id=target;
 update public.spa_payroll_runs set needs_recalculation=true where status='draft' and period_end>=first_day;
 if target is distinct from spa_private.payroll_notice_rule_on((now() at time zone 'Asia/Taipei')::date)
 then raise exception 'CURRENT_RULE_MISMATCH'; end if;
 if exists(select 1 from payroll_preserved_finals p left join public.spa_payroll_runs r on r.id=p.id where to_jsonb(r) is distinct from p.original)
  or exists(select 1 from payroll_preserved_sources p left join public.spa_payroll_source_snapshots s using(run_id,staff_id) where md5(s.packet::text) is distinct from p.original)
 then raise exception 'FINALIZED_SNAPSHOT_CHANGED'; end if;
end $$;
commit;
