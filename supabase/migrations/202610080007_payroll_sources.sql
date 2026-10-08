begin;

-- Separate from the run JSON so ordinary payroll lists never download every
-- source record. A source packet is captured atomically with each saved run.
create table if not exists public.spa_payroll_source_snapshots (
 run_id uuid not null references public.spa_payroll_runs on delete cascade,
 staff_id uuid not null references public.spa_staff,
 packet jsonb not null,
 captured_at timestamptz not null default now(),
 primary key(run_id,staff_id)
);
alter table public.spa_payroll_source_snapshots enable row level security;
revoke all on public.spa_payroll_source_snapshots from public,anon,authenticated;
grant all on public.spa_payroll_source_snapshots to service_role;

create or replace function spa_private.payroll_source_records(p_staff uuid,p_from date,p_to date) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'services',coalesce((select jsonb_agg(jsonb_build_object(
   'id',a.id,'reference',a.reference,'checkout_id',ch.id,'date',a.business_date,'starts_at',a.starts_at,
   'name',coalesce(nullif(a.service_name_snapshot,''),a.service_name),'quantity',1,'duration_minutes',a.duration_minutes_snapshot,
   'settlement_status',case when ch.id is null then 'unsettled' when ch.refunded_at is not null then 'refunded' else 'settled' end,
   'contributes',ch.id is not null and ch.refunded_at is null,
   'gross_cents',ch.gross_cents,'discount_cents',ch.discount_cents,'tea_cents',a.tea_cents,
   'revenue_cents',ch.revenue_cents,'net_cents',case when ch.id is not null and ch.refunded_at is null then greatest(0,ch.revenue_cents-a.tea_cents) else 0 end,
   'designated',coalesce(ch.designated_client_snapshot,false),'snapshot_commission_cents',ch.commission_cents
  ) order by a.business_date,a.starts_at,a.id) from public.spa_appointments a left join public.spa_checkouts ch on ch.appointment_id=a.id
   where a.staff_id=p_staff and a.business_date between p_from and p_to and a.status='completed'),'[]'),
  'pos_services',coalesce((select jsonb_agg(jsonb_build_object(
   'id',i.id,'order_id',o.id,'reference',o.reference,'date',(o.paid_at at time zone 'Asia/Taipei')::date,'paid_at',o.paid_at,
   'name',i.name_snapshot,'quantity',i.quantity,'duration_minutes',i.duration_minutes_snapshot,
   'gross_cents',i.line_total_cents,'net_cents',i.net_total_cents,'designated',i.designated_client_snapshot,
   'snapshot_commission_cents',i.commission_cents,'contributes',true
  ) order by o.paid_at,o.id,i.id) from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
   where i.staff_id=p_staff and i.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),'[]'),
  'products',coalesce((select jsonb_agg(jsonb_build_object(
   'id',i.id,'order_id',o.id,'reference',o.reference,'date',(o.paid_at at time zone 'Asia/Taipei')::date,'paid_at',o.paid_at,
   'name',i.name_snapshot,'quantity',i.quantity,'gross_cents',i.line_total_cents,'net_cents',i.net_total_cents,
   'snapshot_commission_cents',i.commission_cents,'contributes',true
  ) order by o.paid_at,o.id,i.id) from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
   where i.staff_id=p_staff and i.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),'[]'),
  'time_entries',coalesce((select jsonb_agg(jsonb_build_object(
   'id',t.id,'attendance_id',a.id,'date',t.work_date,'started_at',t.started_at,'ended_at',t.ended_at,
   'break_minutes',t.break_minutes,'minutes',greatest(0,floor(extract(epoch from t.ended_at-t.started_at)/60)::int-t.break_minutes),
   'note',t.note,'status',t.status
  ) order by t.work_date,t.started_at,t.id) from public.spa_time_entries t left join public.spa_attendance a on a.time_entry_id=t.id
   where t.staff_id=p_staff and t.work_date between p_from and p_to and t.status='approved'),'[]'),
  'overtime',coalesce((select jsonb_agg(jsonb_build_object(
   'id',o.id,'date',o.work_date,'type',o.overtime_type,'minutes',o.minutes,'reason',o.reason,'status',o.status
  ) order by o.work_date,o.overtime_type,o.id) from public.spa_overtime_entries o
   where o.staff_id=p_staff and o.work_date between p_from and p_to and o.status='approved'),'[]'),
  'overtime_context',coalesce((select jsonb_agg(jsonb_build_object(
   'id',o.id,'date',o.work_date,'type',o.overtime_type,'minutes',o.minutes,
   'in_period',o.work_date between p_from and p_to,
   'in_quarter',o.work_date>=date_trunc('quarter',p_to::timestamp)::date,
   'in_month_range',o.work_date>=date_trunc('month',p_from::timestamp)::date
  ) order by o.work_date,o.overtime_type,o.id) from public.spa_overtime_entries o
   where o.staff_id=p_staff and o.work_date>=least(date_trunc('month',p_from::timestamp)::date,date_trunc('quarter',p_to::timestamp)::date) and o.work_date<=p_to and o.status='approved'),'[]'),
  'adjustments',coalesce((select jsonb_agg(jsonb_build_object(
   'id',a.id,'date',a.period_start,'kind',a.kind,'amount_cents',a.amount_cents,'note',a.note
  ) order by a.period_start,a.created_at,a.id) from public.spa_payroll_adjustments a
   where a.staff_id=p_staff and a.period_start between p_from and p_to),'[]')
 );
$$;

create or replace function spa_private.payroll_source_totals(p_sources jsonb) returns jsonb
language sql immutable set search_path='' as $$
 with services as (
  select x.value row from jsonb_array_elements(p_sources->'services') x
  union all select x.value from jsonb_array_elements(p_sources->'pos_services') x
 ), adjustment as (select value row from jsonb_array_elements(p_sources->'adjustments'))
 select jsonb_build_object(
  'completed_count',(select count(*) from jsonb_array_elements(p_sources->'services'))+coalesce((select sum((value->>'quantity')::bigint) from jsonb_array_elements(p_sources->'pos_services')),0),
  'service_count',coalesce((select sum((row->>'quantity')::bigint) from services where (row->>'contributes')::boolean),0),
  'unsettled_completed_count',(select count(*) from services where row->>'settlement_status'='unsettled'),
  'refunded_service_count',(select count(*) from services where row->>'settlement_status'='refunded'),
  'service_minutes',coalesce((select sum((row->>'quantity')::bigint*(row->>'duration_minutes')::bigint) from services where (row->>'contributes')::boolean),0),
  'service_sales_cents',coalesce((select sum((row->>'net_cents')::bigint) from services),0),
  'product_order_count',(select count(distinct value->>'order_id') from jsonb_array_elements(p_sources->'products')),
  'product_sales_cents',coalesce((select sum((value->>'net_cents')::bigint) from jsonb_array_elements(p_sources->'products')),0),
  'designated_clients',coalesce((select sum((row->>'quantity')::bigint) from services where (row->>'contributes')::boolean and (row->>'designated')::boolean),0),
  'designated_service_sales_cents',coalesce((select sum((row->>'net_cents')::bigint) from services where (row->>'contributes')::boolean and (row->>'designated')::boolean),0),
  'work_minutes',coalesce((select sum((value->>'minutes')::bigint) from jsonb_array_elements(p_sources->'time_entries')),0),
  'overtime_minutes',coalesce((select sum((value->>'minutes')::bigint) from jsonb_array_elements(p_sources->'overtime')),0),
  'overtime_occurrences',(select count(*) from jsonb_array_elements(p_sources->'overtime')),
  'quarter_overtime_minutes',coalesce((select sum((value->>'minutes')::bigint) from jsonb_array_elements(p_sources->'overtime_context') where (value->>'in_quarter')::boolean),0),
  'max_month_overtime_minutes',coalesce((select max(q.minutes) from (select sum((value->>'minutes')::bigint) minutes from jsonb_array_elements(p_sources->'overtime_context') where (value->>'in_month_range')::boolean group by substring(value->>'date' from 1 for 7)) q),0),
  'manual_designated_bonus_cents',coalesce((select sum((row->>'amount_cents')::bigint) from adjustment where row->>'kind'='designated_bonus'),0),
  'bonus_cents',coalesce((select sum((row->>'amount_cents')::bigint) from adjustment where row->>'kind'='bonus'),0),
  'allowance_cents',coalesce((select sum((row->>'amount_cents')::bigint) from adjustment where row->>'kind'='allowance'),0),
  'deduction_cents',coalesce((select sum((row->>'amount_cents')::bigint) from adjustment where row->>'kind'='deduction'),0)
 );
$$;

create or replace function spa_private.payroll_rule_reference(p_rule uuid,p_wage jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'version',(select to_jsonb(v)-'created_by' from public.spa_payroll_rule_versions v where v.id=p_rule),
  'profile',jsonb_build_object('job_title_id',p_wage->'job_title_id','title',p_wage->'role','employment_type_code',p_wage->'employment_type_code',
   'pay_basis',p_wage->'pay_basis','base_pay_rate_cents',p_wage->'base_pay_rate_cents','service_commission_bps',p_wage->'service_commission_bps',
   'product_commission_bps',p_wage->'product_commission_bps','designated_bonus_bps',p_wage->'designated_bonus_bps',
   'minimum_attendance_minutes',p_wage->'minimum_attendance_minutes','commission_start_service_minutes',p_wage->'commission_start_service_minutes'),
  'rates',coalesce((select jsonb_agg(to_jsonb(r) order by overtime_type,start_minute) from public.spa_payroll_overtime_rates r
   where r.rule_version_id=p_rule and r.employment_type_code=p_wage->>'employment_type_code'),'[]'),
  'tiers',coalesce((select jsonb_agg(to_jsonb(t) order by metric,threshold_from,id) from public.spa_payroll_commission_tiers t
   where t.rule_version_id=p_rule and t.job_title_id=(p_wage->>'job_title_id')::uuid and t.employment_type_code=p_wage->>'employment_type_code'),'[]')
 );
$$;

create or replace function spa_private.payroll_source_packet(p_staff uuid,p_from date,p_to date,p_rule uuid,p_wage jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare records jsonb:=spa_private.payroll_source_records(p_staff,p_from,p_to);
begin
 return jsonb_build_object('schema_version',1,'staff_id',p_staff,'from',p_from,'to',p_to,'captured_at',now(),
  'sources',records,'source_totals',spa_private.payroll_source_totals(records),'rule_reference',spa_private.payroll_rule_reference(p_rule,p_wage));
end $$;

create or replace function spa_private.payroll_capture_sources() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 delete from public.spa_payroll_source_snapshots where run_id=new.id;
 insert into public.spa_payroll_source_snapshots(run_id,staff_id,packet)
 select new.id,(x.value->>'staff_id')::uuid,spa_private.payroll_source_packet((x.value->>'staff_id')::uuid,new.period_start,new.period_end,new.rule_version_id,x.value)
 from jsonb_array_elements(coalesce(new.calculation_snapshot->'rows','[]')) x;
 return new;
end $$;
drop trigger if exists spa_payroll_capture_sources on public.spa_payroll_runs;
create trigger spa_payroll_capture_sources after update of calculation_snapshot on public.spa_payroll_runs for each row execute function spa_private.payroll_capture_sources();

create or replace function public.spa_payroll_sources(p_staff uuid,p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare person uuid:=p_staff; own_staff uuid; is_owner boolean; payroll_run public.spa_payroll_runs; rule_id uuid:=p_rule;
 current_wage jsonb; finalized_wage jsonb; wage jsonb; packet jsonb; basis text:='preview'; evidence text:='live'; checks jsonb; component_total bigint;
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select r.role='owner',r.staff_id into is_owner,own_staff from public.spa_roles r where r.user_id=auth.uid() and r.active;
 if not coalesce(is_owner,false) then
  if own_staff is null or (person is not null and person<>own_staff) or p_rule is not null then raise exception 'FORBIDDEN'; end if;
  person:=own_staff;
 end if;
 if person is null or not exists(select 1 from public.spa_staff where id=person) then raise exception 'NOT_FOUND'; end if;
 select * into payroll_run from public.spa_payroll_runs r where r.period_start=p_from and r.period_end=p_to;
 if payroll_run.status='finalized' then
  select x.value into finalized_wage from jsonb_array_elements(coalesce(payroll_run.calculation_snapshot->'rows','[]')) x where x.value->>'staff_id'=person::text;
  if finalized_wage is null then
   -- Older runs may retain item snapshots without the full later row JSON.
   -- Map only saved fields; never borrow today's title or compensation profile
   -- and present it as a historical wage.
   select (to_jsonb(i)-array['id','run_id','staff_name_snapshot','employment_type_snapshot','role_snapshot','pay_basis_snapshot','commission_bps_snapshot','calculation_snapshot'])
    ||jsonb_build_object('employee',i.staff_name_snapshot,'employment_type',i.employment_type_snapshot,'role',i.role_snapshot,
     'pay_basis',i.pay_basis_snapshot,'commission_bps',i.commission_bps_snapshot,'service_commission_bps',i.commission_bps_snapshot,'calculation',i.calculation_snapshot)
   into finalized_wage from public.spa_payroll_items i where i.run_id=payroll_run.id and i.staff_id=person;
  end if;
  if p_rule is null and finalized_wage is null then raise exception 'NOT_FOUND'; end if;
 end if;
 if rule_id is null then select id into rule_id from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1; end if;
 rule_id:=coalesce(rule_id,payroll_run.rule_version_id);
 select x.value into current_wage from jsonb_array_elements(spa_private.payroll_preview(p_from,p_to,rule_id)) x where x.value->>'staff_id'=person::text;
 wage:=current_wage;
 if p_rule is null and finalized_wage is not null then
  wage:=finalized_wage; basis:='finalized';
  select s.packet into packet from public.spa_payroll_source_snapshots s where s.run_id=payroll_run.id and s.staff_id=person;
  if packet is not null then evidence:='snapshot'; else evidence:='legacy_current_records'; end if;
 end if;
 if wage is null then raise exception 'NOT_FOUND'; end if;
 if packet is null then packet:=spa_private.payroll_source_packet(person,p_from,p_to,case when basis='finalized' then payroll_run.rule_version_id else rule_id end,wage); end if;
 select coalesce(jsonb_agg(jsonb_build_object('key',s.key,'expected',(wage->>s.key)::bigint,'actual',s.value::text::bigint,
  'matches',case when wage?s.key then (wage->>s.key)::bigint=s.value::text::bigint else null end) order by s.key),'[]') into checks
 from jsonb_each(packet->'source_totals') s;
 component_total:=coalesce((wage->>'base_cents')::bigint,0)+coalesce((wage->>'service_commission_cents')::bigint,0)+coalesce((wage->>'product_commission_cents')::bigint,0)+coalesce((wage->>'designated_bonus_cents')::bigint,0)+coalesce((wage->>'overtime_cents')::bigint,0)+coalesce((wage->>'bonus_cents')::bigint,0)+coalesce((wage->>'allowance_cents')::bigint,0)-coalesce((wage->>'deduction_cents')::bigint,0);
 return jsonb_build_object('staff_id',person,'from',p_from,'to',p_to,'basis',basis,'evidence_mode',evidence,'captured_at',packet->'captured_at',
  'wage',wage,'current_wage',current_wage,'finalized_wage',finalized_wage,
  'run',case when payroll_run.id is null then null else jsonb_build_object('id',payroll_run.id,'status',payroll_run.status,'rule_version_id',payroll_run.rule_version_id,'finalized_at',payroll_run.finalized_at,'needs_recalculation',payroll_run.needs_recalculation) end,
  'sources',packet->'sources','source_totals',packet->'source_totals','rule_reference',packet->'rule_reference',
  'reconciliation',jsonb_build_object('checks',checks,'source_matches',not exists(select 1 from jsonb_array_elements(checks) c where c->>'matches'='false'),
   'formula_total_cents',greatest(0,component_total),'formula_before_floor_cents',component_total,'formula_matches',greatest(0,component_total)=coalesce((wage->>'total_cents')::bigint,0),
   'historical_sources_complete',evidence<>'legacy_current_records'));
end $$;

revoke all on function spa_private.payroll_source_records(uuid,date,date),spa_private.payroll_source_totals(jsonb),spa_private.payroll_rule_reference(uuid,jsonb),spa_private.payroll_source_packet(uuid,date,date,uuid,jsonb),spa_private.payroll_capture_sources() from public,anon,authenticated;
revoke all on function public.spa_payroll_sources(uuid,date,date,uuid) from public,anon,authenticated;
grant execute on function public.spa_payroll_sources(uuid,date,date,uuid) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
