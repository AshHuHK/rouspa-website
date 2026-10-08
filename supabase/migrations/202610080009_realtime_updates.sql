begin;

-- This channel grants invalidation hints only. All actual records remain behind
-- existing RPC permissions; no business table is added to a publication.
create or replace function spa_private.can_receive_operations() returns boolean
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_team();
 return true;
exception when insufficient_privilege then return false;
end $$;
revoke all on function spa_private.can_receive_operations() from public,anon,authenticated;
grant execute on function spa_private.can_receive_operations() to authenticated;

-- Realtime owns its schema and already enables RLS. Manage only our narrowly
-- scoped receive policy; do not change its table ownership, grants or RLS flag.
do $$ begin
 if to_regclass('realtime.messages') is not null then
  execute 'drop policy if exists rou_spa_operations_receive on realtime.messages';
  execute $policy$create policy rou_spa_operations_receive on realtime.messages
   for select to authenticated using (
    extension='broadcast' and topic='rou-spa:operations' and (select realtime.topic())='rou-spa:operations'
    and (select spa_private.can_receive_operations())
   )$policy$;
 end if;
end $$;

-- One row per transaction/audience. The deferred INSERT trigger reads the final
-- union of all scopes and deletes this internal row before commit. This keeps
-- checkout/POS/payroll transactions from emitting a message for every write.
create table if not exists spa_private.live_invalidations (
 transaction_id bigint not null,
 audience text not null check(audience in ('operations','public')),
 scopes text[] not null,
 primary key(transaction_id,audience)
);
alter table spa_private.live_invalidations enable row level security;
revoke all on spa_private.live_invalidations from public,anon,authenticated;

create or replace function spa_private.flush_live_invalidation() returns trigger
language plpgsql security definer set search_path='' as $$
declare hints text[];
begin
 select scopes into hints from spa_private.live_invalidations
 where transaction_id=new.transaction_id and audience=new.audience;
 if hints is null then return null; end if;
 delete from spa_private.live_invalidations
 where transaction_id=new.transaction_id and audience=new.audience;
 -- Local PGlite / vanilla Postgres fixtures do not install Supabase Realtime.
 -- Skip only a missing transport; do not swallow unrelated database failures.
 if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null then
  perform realtime.send(jsonb_build_object('scopes',hints,'timestamp',clock_timestamp()),
   'invalidate','rou-spa:'||new.audience,new.audience='operations');
 end if;
 return null;
end $$;
revoke all on function spa_private.flush_live_invalidation() from public,anon,authenticated;
drop trigger if exists spa_live_invalidation_flush on spa_private.live_invalidations;
create constraint trigger spa_live_invalidation_flush after insert on spa_private.live_invalidations
 deferrable initially deferred for each row execute function spa_private.flush_live_invalidation();

create or replace function spa_private.queue_live_invalidation() returns trigger
language plpgsql security definer set search_path='' as $$
declare target text; hints text[]; i integer;
begin
 -- Arguments are static scope allowlists, never NEW/OLD values or row IDs.
 for i in 0..1 loop
  target:=case when i=0 then 'operations' else 'public' end;
  hints:=string_to_array(tg_argv[i],',');
  if cardinality(hints)>0 then
   insert into spa_private.live_invalidations as queue(transaction_id,audience,scopes)
   values(txid_current(),target,hints)
   on conflict(transaction_id,audience) do update set scopes=(
    select array_agg(distinct scope order by scope) from unnest(queue.scopes||excluded.scopes) scope
   );
  end if;
 end loop;
 return null;
end $$;
revoke all on function spa_private.queue_live_invalidation() from public,anon,authenticated;

-- Public hints are restricted to catalogue, hours, slot availability and one
-- generic member hint. Member/lookup details still require their access-token
-- RPC; the hint carries no member IDs, counts, status, balance, or record data.
-- The private channel includes every durable source used by staff views/todos.
do $$
declare mapping text[]; item text; parts text[];
begin
 mapping:=array[
  'spa_appointments|appointments,payroll,availability|availability,member',
  'spa_appointment_staff_changes|appointments,payroll|availability',
  'spa_checkouts|appointments,checkouts,balances,coupons,payroll,sales|member',
  'spa_orders|orders,inventory,balances,coupons,payroll,sales|member',
  'spa_order_items|orders,inventory,payroll,sales|member',
  'spa_sale_requests|orders,checkouts,sales|member',
  'spa_inventory_entries|inventory,orders,catalog|catalog',
  'spa_reviews|reviews,coupons|member',
  'spa_feedback|reviews|',
  'spa_coupons|coupons,checkouts,orders|member',
  'spa_shifts|schedule,availability|availability',
  'spa_daily_shifts|schedule,attendance,availability|availability',
  'spa_time_off|schedule,availability|availability',
  'spa_staff_schedule_submissions|schedule|',
  'spa_staff_schedule_change_requests|schedule|',
  'spa_time_entries|attendance,payroll|',
  'spa_overtime_entries|attendance,payroll|',
  'spa_payroll_adjustments|payroll|',
  'spa_payroll_runs|payroll|',
  'spa_payroll_items|payroll|',
  'spa_payroll_source_snapshots|payroll|',
  'spa_payroll_rule_versions|payroll,settings|',
  'spa_payroll_overtime_rates|payroll,settings|',
  'spa_payroll_commission_tiers|payroll,settings|',
  'spa_compensation_profiles|payroll,settings,team|',
  'spa_attendance|attendance,payroll|',
  'spa_attendance_events|attendance|',
  'spa_attendance_requests|attendance,payroll|',
  'spa_attendance_settings|attendance,settings|',
  'spa_settings|settings,availability,hours|hours,availability',
  'spa_business_settings|settings,payroll|',
  'spa_business_hours|settings,hours,schedule,availability|hours,availability',
  'spa_business_day_overrides|settings,hours,schedule,availability|hours,availability',
  'spa_staff|team,schedule,payroll,catalog,availability|catalog,availability',
  'spa_roles|team,settings|',
  'spa_role_profiles|team,settings|',
  'spa_role_permissions|team,settings|',
  'spa_permission_definitions|team,settings|',
  'spa_job_titles|team,payroll,settings|',
  'spa_employment_types|team,payroll,settings|',
  'spa_services|catalog,appointments,orders,availability|catalog,availability',
  'spa_staff_services|catalog,team,schedule,availability|catalog,availability',
  'spa_service_categories|catalog|catalog',
  'spa_service_addon_targets|catalog,appointments,availability|catalog,availability',
  'spa_products|catalog,inventory,orders|catalog',
  'spa_product_categories|catalog|catalog',
  'spa_rooms|settings,schedule,availability|availability',
  'spa_packages|catalog,balances|catalog,member',
  'spa_package_entries|balances,checkouts|member',
  'spa_wallet_entries|balances,checkouts|member',
  'spa_customers|customers,appointments,orders,balances,coupons|member',
  'spa_cash_entries|sales,checkouts,orders|',
  'spa_audit|audit|'
 ];
 foreach item in array mapping loop
  parts:=string_to_array(item,'|');
  if to_regclass('public.'||parts[1]) is not null then
   execute format('drop trigger if exists spa_live_invalidation on public.%I',parts[1]);
   execute format('create trigger spa_live_invalidation after insert or update or delete or truncate on public.%I for each statement execute function spa_private.queue_live_invalidation(%L,%L)',parts[1],parts[2],parts[3]);
  end if;
 end loop;
end $$;

notify pgrst,'reload schema';
commit;
