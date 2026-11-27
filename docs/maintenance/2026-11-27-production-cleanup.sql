-- One-time production maintenance, after reviewing references and explicit
-- deletion approval. This is intentionally not an automatic migration.
begin;
do $$
declare targets uuid[]; dependency record; references_found bigint; actor uuid;
 safe_tables text[]:=array['spa_staff_services','spa_shifts','spa_daily_shifts','spa_time_off',
 'spa_staff_schedule_submissions','spa_staff_schedule_change_requests','payroll_notice_staff','spa_roles'];
begin
 perform pg_advisory_xact_lock(726001);
 perform pg_advisory_xact_lock(726005);
 perform pg_advisory_xact_lock(726099);
 select user_id into actor from public.spa_roles where role='owner' and active limit 1;
 if actor is null then raise exception 'OWNER_REQUIRED'; end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 select array_agg(s.id) into targets from public.spa_staff s join (values
 ('陳柏翰','Chen Bo-Han'),('王詩涵','Wang Shi-Han'),('張家豪','Zhang Jia-Hao'),('李靜怡','Li Jing-Yi'),('吳俊霖','Wu Jun-Lin')) seed(name,name_en)
 on s.name=seed.name and s.name_en=seed.name_en
 where s.archived_at is not null and not s.active;
 if coalesce(array_length(targets,1),0)>0 then
  if exists(select 1 from public.spa_roles where staff_id=any(targets) and (active or role='owner')) then raise exception 'DEMO_HAS_LIVE_ACCOUNT'; end if;
  -- Any financial, attendance, customer or other unexpected reference aborts
  -- the entire transaction. Never cascade into real operating history.
  for dependency in
   select n.nspname schema_name,c.relname table_name,a.attname column_name
   from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace
   join pg_attribute a on a.attrelid=c.oid and a.attnum=any(k.conkey)
   where k.contype='f' and k.confrelid='public.spa_staff'::regclass
  loop
   if not dependency.table_name=any(safe_tables) then
    execute format('select count(*) from %I.%I where %I=any($1)',dependency.schema_name,dependency.table_name,dependency.column_name) into references_found using targets;
    if references_found>0 then raise exception 'DEMO_HAS_BUSINESS_HISTORY: %.%',dependency.schema_name,dependency.table_name; end if;
   end if;
  end loop;
  for dependency in
   select n.nspname schema_name,c.relname table_name,a.attname column_name
   from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace
   join pg_attribute a on a.attrelid=c.oid and a.attnum=any(k.conkey)
   where k.contype='f' and k.confrelid='public.spa_staff'::regclass and c.relname=any(safe_tables)
  loop
   execute format('delete from %I.%I where %I=any($1)',dependency.schema_name,dependency.table_name,dependency.column_name) using targets;
  end loop;
  perform spa_private.audit('maintenance.unused_demo_removed',null,jsonb_build_object('count',array_length(targets,1),'staff_ids',targets));
  delete from public.spa_staff where id=any(targets);
 end if;
 -- The v5 finalized wage and v6 checkout references remain traceable.
 -- Older versions used before December remain available to the date resolver.
 for dependency in select id from public.spa_payroll_rule_versions v where version_no in (1,3) and status='archived'
 loop
  perform public.spa_payroll_rule_delete(dependency.id,'DELETE');
 end loop;
end $$;
commit;
select not exists(select 1 from public.spa_staff where name in ('陳柏翰','王詩涵','張家豪','李靜怡','吳俊霖')) demo_staff_removed,
 not exists(select 1 from public.spa_payroll_rule_versions where version_no in (1,3)) unused_versions_removed,
 (select count(*) from public.spa_staff where name in ('安然','沐茗','珞櫻') and active and archived_at is null)=3 current_technicians_preserved;
