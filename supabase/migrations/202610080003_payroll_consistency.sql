begin;

-- Freeze POS service duration and designation when the sale is recorded. Old
-- sales can only be initialized from the currently retained catalogue/profile;
-- finalized wage snapshots are deliberately left untouched.
alter table public.spa_order_items
 add column if not exists duration_minutes_snapshot int,
 add column if not exists designated_client_snapshot boolean,
 add column if not exists commission_bps_snapshot int,
 add column if not exists net_total_cents bigint;
alter table public.spa_checkouts add column if not exists designated_client_snapshot boolean;
alter table public.spa_payroll_runs add column if not exists needs_recalculation boolean not null default false;

update public.spa_order_items i set
 duration_minutes_snapshot=case when i.item_type='service' then (select duration_minutes from public.spa_services where id=i.service_id) else 0 end,
 designated_client_snapshot=coalesce(i.item_type='service' and i.staff_id=(select c.preferred_staff_id from public.spa_orders o join public.spa_customers c on c.id=o.customer_id where o.id=i.order_id),false),
 commission_bps_snapshot=case when i.line_total_cents>0 then least(10000,round(i.commission_cents*10000.0/i.line_total_cents)::int) else 0 end
where i.duration_minutes_snapshot is null;

with allocation as (
 select i.id,i.line_total_cents,o.total_cents,
  sum(i.line_total_cents) over(partition by i.order_id) gross,
  sum(i.line_total_cents) over(partition by i.order_id order by i.id rows unbounded preceding) cumulative
 from public.spa_order_items i join public.spa_orders o on o.id=i.order_id
), net as (
 select id,case when gross>0 then floor(cumulative*total_cents::numeric/gross)-floor((cumulative-line_total_cents)*total_cents::numeric/gross) else 0 end::bigint amount from allocation
)
update public.spa_order_items i set net_total_cents=n.amount from net n where i.id=n.id and i.net_total_cents is null;

update public.spa_checkouts ch set designated_client_snapshot=coalesce((
 select a.booking_preference='designated' or (a.booking_preference='legacy' and c.preferred_staff_id=a.staff_id)
 from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id where a.id=ch.appointment_id),false)
where ch.designated_client_snapshot is null;

alter table public.spa_order_items
 alter column duration_minutes_snapshot set default 0,
 alter column duration_minutes_snapshot set not null,
 alter column designated_client_snapshot set default false,
 alter column designated_client_snapshot set not null,
 alter column commission_bps_snapshot set default 0,
 alter column commission_bps_snapshot set not null,
 alter column net_total_cents set default 0,
 alter column net_total_cents set not null;
alter table public.spa_checkouts alter column designated_client_snapshot set default false,alter column designated_client_snapshot set not null;

create or replace function spa_private.payroll_sale_snapshot() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='spa_order_items' then
  new.duration_minutes_snapshot:=case when new.item_type='service' then (select duration_minutes from public.spa_services where id=new.service_id) else 0 end;
  new.designated_client_snapshot:=coalesce(new.item_type='service' and new.staff_id=(select c.preferred_staff_id from public.spa_orders o join public.spa_customers c on c.id=o.customer_id where o.id=new.order_id),false);
  select case when new.item_type='service' then coalesce(c.service_commission_bps,0) else coalesce(c.product_commission_bps,0) end
  into new.commission_bps_snapshot from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=new.staff_id;
  new.commission_bps_snapshot:=coalesce(new.commission_bps_snapshot,0); new.net_total_cents:=new.line_total_cents;
 else
  select coalesce(a.booking_preference='designated' or (a.booking_preference='legacy' and c.preferred_staff_id=a.staff_id),false)
  into new.designated_client_snapshot from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id where a.id=new.appointment_id;
 end if;
 return new;
end $$;

create or replace function spa_private.payroll_draft_changed() returns trigger
language plpgsql security definer set search_path='' as $$
declare old_day date; new_day date;
begin
 perform pg_advisory_xact_lock(726099);
 if tg_table_name='spa_time_entries' then
  if tg_op<>'INSERT' then old_day:=old.work_date; end if;
  if tg_op<>'DELETE' then new_day:=new.work_date; end if;
  update public.spa_payroll_runs r set needs_recalculation=true where r.status='draft' and (old_day between r.period_start and r.period_end or new_day between r.period_start and r.period_end);
 else
  update public.spa_payroll_runs set needs_recalculation=true where status='draft';
 end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
drop trigger if exists spa_payroll_time_draft_changed on public.spa_time_entries;
create trigger spa_payroll_time_draft_changed after insert or update or delete on public.spa_time_entries for each row execute function spa_private.payroll_draft_changed();
drop trigger if exists spa_payroll_profile_draft_changed on public.spa_compensation_profiles;
create trigger spa_payroll_profile_draft_changed after insert or update or delete on public.spa_compensation_profiles for each statement execute function spa_private.payroll_draft_changed();
drop trigger if exists spa_payroll_staff_draft_changed on public.spa_staff;
create trigger spa_payroll_staff_draft_changed after update of job_title_id,employment_type_code,active,employment_status,departed_on,hire_date on public.spa_staff for each statement execute function spa_private.payroll_draft_changed();
drop trigger if exists spa_payroll_rate_draft_changed on public.spa_payroll_overtime_rates;
create trigger spa_payroll_rate_draft_changed after insert or update or delete on public.spa_payroll_overtime_rates for each statement execute function spa_private.payroll_draft_changed();
drop trigger if exists spa_payroll_tier_draft_changed on public.spa_payroll_commission_tiers;
create trigger spa_payroll_tier_draft_changed after insert or update or delete on public.spa_payroll_commission_tiers for each statement execute function spa_private.payroll_draft_changed();

drop trigger if exists spa_payroll_order_snapshot on public.spa_order_items;
create trigger spa_payroll_order_snapshot before insert on public.spa_order_items for each row execute function spa_private.payroll_sale_snapshot();
drop trigger if exists spa_payroll_checkout_snapshot on public.spa_checkouts;
create trigger spa_payroll_checkout_snapshot before insert on public.spa_checkouts for each row execute function spa_private.payroll_sale_snapshot();

-- Allocate order-level discounts once, in integer cents. Cumulative allocation
-- avoids rounding drift: all line net amounts add up to the actual order total.
create or replace function spa_private.payroll_pos_allocate() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='paid' and (tg_op='INSERT' or old.status is distinct from new.status or old.total_cents is distinct from new.total_cents) then
  with allocation as (
   select i.id,i.line_total_cents,sum(i.line_total_cents) over() gross,
    sum(i.line_total_cents) over(order by i.id rows unbounded preceding) cumulative
   from public.spa_order_items i where i.order_id=new.id
  ), net as (
   select id,case when gross>0 then floor(cumulative*new.total_cents::numeric/gross)-floor((cumulative-line_total_cents)*new.total_cents::numeric/gross) else 0 end::bigint amount from allocation
  ) update public.spa_order_items i set net_total_cents=n.amount,commission_cents=round(n.amount*i.commission_bps_snapshot/10000.0)::bigint from net n where i.id=n.id;
 end if;
 return new;
end $$;
drop trigger if exists spa_payroll_pos_allocate on public.spa_orders;
create trigger spa_payroll_pos_allocate after insert or update on public.spa_orders for each row execute function spa_private.payroll_pos_allocate();

-- Every fact used by a finalized wage period shares the attendance/finalization
-- lock. Changes to unrelated notes remain allowed; wage facts require reopening.
create or replace function spa_private.payroll_input_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare old_day date; new_day date;
begin
 perform pg_advisory_xact_lock(726099);
 if tg_op='UPDATE' then
  if tg_table_name='spa_appointments' then
   if new.staff_id is not distinct from old.staff_id and new.business_date is not distinct from old.business_date and new.status is not distinct from old.status and new.duration_minutes_snapshot is not distinct from old.duration_minutes_snapshot and new.price_cents is not distinct from old.price_cents and new.tea_cents is not distinct from old.tea_cents and new.customer_id is not distinct from old.customer_id and new.booking_preference is not distinct from old.booking_preference then return new; end if;
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
drop trigger if exists spa_payroll_adjustment_guard on public.spa_payroll_adjustments;
create trigger spa_payroll_adjustment_guard before insert or update or delete on public.spa_payroll_adjustments for each row execute function spa_private.payroll_input_guard();
drop trigger if exists spa_payroll_overtime_guard on public.spa_overtime_entries;
create trigger spa_payroll_overtime_guard before insert or update or delete on public.spa_overtime_entries for each row execute function spa_private.payroll_input_guard();
drop trigger if exists spa_payroll_appointment_guard on public.spa_appointments;
create trigger spa_payroll_appointment_guard before insert or update or delete on public.spa_appointments for each row execute function spa_private.payroll_input_guard();
drop trigger if exists spa_payroll_checkout_guard on public.spa_checkouts;
create trigger spa_payroll_checkout_guard before insert or update or delete on public.spa_checkouts for each row execute function spa_private.payroll_input_guard();
drop trigger if exists spa_payroll_order_guard on public.spa_orders;
create trigger spa_payroll_order_guard before insert or update or delete on public.spa_orders for each row execute function spa_private.payroll_input_guard();
drop trigger if exists spa_payroll_order_item_guard on public.spa_order_items;
create trigger spa_payroll_order_item_guard before insert or update or delete on public.spa_order_items for each row execute function spa_private.payroll_input_guard();
create or replace function spa_private.payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 if version.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 return coalesce((with staff_metrics as (
  select s.id,s.name,s.job_title_id,j.name title,e.name employment_type,s.employment_type_code,s.employment_status,s.departed_on,
   cp.job_title_id is not null compensation_configured,coalesce(cp.pay_basis,'monthly') pay_basis,coalesce(cp.base_pay_cents,0) base_pay_cents,coalesce(cp.service_commission_bps,0) service_commission_bps,
   coalesce(cp.product_commission_bps,0) product_commission_bps,coalesce(cp.designated_client_bonus_bps,0) designated_bonus_bps,
   coalesce(cp.minimum_attendance_minutes,0) minimum_attendance_minutes,coalesce(cp.commission_start_service_minutes,0) commission_start_service_minutes,
   coalesce((select sum(greatest(0,floor(extract(epoch from te.ended_at-te.started_at)/60)::int-te.break_minutes)) from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved'),0)::bigint work_minutes,
   (coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint completed_count,
   (coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_count,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),0)::bigint unsettled_completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is not null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint refunded_service_count,
   (coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity*oi.duration_minutes_snapshot) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services svc on svc.id=oi.service_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_minutes,
   (coalesce((select sum(greatest(0,ch.revenue_cents-a.tea_cents)) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.net_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_sales_cents,
   coalesce((select count(distinct o.id) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_order_count,
   coalesce((select sum(oi.net_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_sales_cents,
   (coalesce((select sum(greatest(0,ch.revenue_cents-a.tea_cents)) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and ch.designated_client_snapshot and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.net_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_customers c on c.id=o.customer_id where oi.staff_id=s.id and oi.item_type='service' and oi.designated_client_snapshot and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint designated_service_sales_cents,
   (coalesce((select count(*) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and ch.designated_client_snapshot and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_customers c on c.id=o.customer_id where oi.staff_id=s.id and oi.item_type='service' and oi.designated_client_snapshot and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint designated_clients,
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint manual_designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to),0)::bigint deduction_cents,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_minutes,
   coalesce((select count(*) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_occurrences,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date>=date_trunc('quarter',p_to::timestamp)::date and o.work_date<=p_to and o.status='approved'),0)::bigint quarter_overtime_minutes,
   coalesce((select max(q.minutes) from (select sum(o.minutes) minutes from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date>=date_trunc('month',p_from::timestamp)::date and o.work_date<=p_to and o.status='approved' group by date_trunc('month',o.work_date::timestamp)) q),0)::bigint max_month_overtime_minutes,
   exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved' and o.overtime_type='weekday' group by o.work_date having sum(o.minutes)>240) daily_limit_exceeded
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code
  left join public.spa_compensation_profiles cp on cp.job_title_id=s.job_title_id and cp.employment_type_code=s.employment_type_code and cp.active
  where coalesce(s.hire_date,s.created_at::date)<=p_to and ((s.employment_status='active' and s.active and s.archived_at is null)
   or (s.employment_status='departed' and s.departed_on is not null and s.departed_on>=p_from)
   or exists(select 1 from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to)
   or exists(select 1 from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved')
   or exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved')
   or exists(select 1 from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to)
   or exists(select 1 from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start between p_from and p_to))
 ), commission as (
  select m.*,
   spa_private.payroll_tier_commission(version.id,m.job_title_id,m.employment_type_code,'service',
    case when exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.job_title_id=m.job_title_id and t.employment_type_code=m.employment_type_code and t.metric='service_minutes') then m.service_minutes
         when exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.job_title_id=m.job_title_id and t.employment_type_code=m.employment_type_code and t.metric='service_count') then m.service_count
         when exists(select 1 from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.job_title_id=m.job_title_id and t.employment_type_code=m.employment_type_code and t.metric='service_sales_cents') then m.service_sales_cents else m.service_minutes end,
    m.service_sales_cents,m.service_commission_bps,m.commission_start_service_minutes,m.compensation_configured and m.work_minutes>=m.minimum_attendance_minutes) calculated_service_commission_cents,
   spa_private.payroll_tier_commission(version.id,m.job_title_id,m.employment_type_code,'product',m.product_sales_cents,m.product_sales_cents,m.product_commission_bps,0,m.compensation_configured) calculated_product_commission_cents
  from staff_metrics m
 ), base_calc as (
  select c.*,round(c.designated_service_sales_cents*c.designated_bonus_bps/10000.0)::bigint+c.manual_designated_bonus_cents designated_bonus_cents,
   case when c.pay_basis='monthly' then c.base_pay_cents when c.pay_basis='hourly' then round(c.base_pay_cents*c.work_minutes/60.0)::bigint else c.base_pay_cents*c.service_count end base_cents from commission c
 ), overtime_calc as (
  select b.*,coalesce((select round(sum((case when b.pay_basis='monthly' then (b.base_pay_cents+case when version.include_regular_commission then b.calculated_service_commission_cents+b.calculated_product_commission_cents+b.designated_bonus_cents else 0 end)/version.hourly_divisor::numeric when b.pay_basis='hourly' then b.base_pay_cents::numeric else 0 end)*greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint from (select staff_id,work_date,overtime_type,sum(minutes)::int minutes from public.spa_overtime_entries where status='approved' group by staff_id,work_date,overtime_type) o join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type where o.staff_id=b.id and o.work_date between p_from and p_to and o.minutes>r.start_minute),0) overtime_cents,
   coalesce((select sum(case when b.pay_basis='session' then o.minutes else greatest(0,o.minutes-coalesce((select sum(greatest(0,least(o.minutes,r.end_minute)-r.start_minute)) from public.spa_payroll_overtime_rates r where r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type and o.minutes>r.start_minute),0)) end) from (select work_date,overtime_type,sum(minutes)::int minutes from public.spa_overtime_entries where staff_id=b.id and work_date between p_from and p_to and status='approved' group by work_date,overtime_type) o),0)::bigint unpriced_overtime_minutes from base_calc b
 )
 select jsonb_agg(jsonb_build_object('staff_id',id,'employee',name,'role',title,'job_title_id',job_title_id,'employment_type',employment_type,'employment_type_code',employment_type_code,'employment_status',employment_status,'departed_on',departed_on,
  'pay_basis',pay_basis,'base_pay_rate_cents',base_pay_cents,'commission_bps',service_commission_bps,'service_commission_bps',service_commission_bps,'product_commission_bps',product_commission_bps,'designated_bonus_bps',designated_bonus_bps,
  'minimum_attendance_minutes',minimum_attendance_minutes,'commission_start_service_minutes',commission_start_service_minutes,'commission_eligibility_met',work_minutes>=minimum_attendance_minutes,
  'work_minutes',work_minutes,'completed_count',completed_count,'service_count',service_count,'unsettled_completed_count',unsettled_completed_count,'refunded_service_count',refunded_service_count,'service_minutes',service_minutes,'service_sales_cents',service_sales_cents,
  'product_order_count',product_order_count,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'designated_service_sales_cents',designated_service_sales_cents,'manual_designated_bonus_cents',manual_designated_bonus_cents,'overtime_occurrences',overtime_occurrences,'overtime_minutes',overtime_minutes,'quarter_overtime_minutes',quarter_overtime_minutes,'max_month_overtime_minutes',max_month_overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',calculated_service_commission_cents,'product_commission_cents',calculated_product_commission_cents,'designated_bonus_cents',designated_bonus_cents,'overtime_cents',overtime_cents,
  'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,'total_cents',greatest(0,base_cents+calculated_service_commission_cents+calculated_product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'unpriced_overtime_minutes',unpriced_overtime_minutes,'overtime_warning',case when unpriced_overtime_minutes>0 then '加班分鐘未完整設定倍率或時薪' when quarter_overtime_minutes>version.quarterly_overtime_limit_minutes then '超過季度加班上限' when max_month_overtime_minutes>version.agreed_monthly_limit_minutes then '超過勞資會議同意月上限' when max_month_overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般月上限，需勞資會議同意' when daily_limit_exceeded then '平日單日延長工時超過 4 小時' else '' end,
  'compensation_configured',compensation_configured,'commission_warning',case when not compensation_configured then '職稱薪資未設定' when work_minutes<minimum_attendance_minutes then '出勤未達提成門檻' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission,'compensation_source','job_title_and_employment_type','tier_scope','job_title_and_employment_type','tier_mode','progressive_or_flat','designated_bonus_basis','designated_service_revenue','service_basis','completed_and_settled','attribution_source','actual_staff','adjustment_date_basis','selected_range','pos_revenue_basis','net_after_order_discount','service_duration_basis','sale_snapshot','designation_basis','sale_snapshot','work_minutes_rounding','floor','money_unit','cents','percentage_unit','basis_points','time_unit','minutes','component_total_before_floor_cents',base_cents+calculated_service_commission_cents+calculated_product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents,'total_floor_zero',true)) order by name) from overtime_calc),'[]'::jsonb);
end $$;


create or replace function public.spa_payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return spa_private.payroll_preview(p_from,p_to,p_rule);
end $$;

create or replace function public.spa_payroll_staff_detail(p_staff uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'NOT_FOUND'; end if;
 return jsonb_build_object(
  'profile',(select to_jsonb(s)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code where s.id=p_staff),
  'services',coalesce((select jsonb_agg(to_jsonb(x) order by x.business_date,x.starts_at) from (select a.id,a.reference,a.business_date,a.starts_at,a.service_name_snapshot service_name,a.duration_minutes_snapshot service_minutes,case when ch.id is null then 'unsettled' when ch.refunded_at is not null then 'refunded' else 'settled' end settlement_status,greatest(0,ch.revenue_cents-a.tea_cents) revenue_cents,ch.designated_client_snapshot,ch.commission_cents,(select count(*) from public.spa_reviews r where r.appointment_id=a.id) review_count from public.spa_appointments a left join public.spa_checkouts ch on ch.appointment_id=a.id where a.staff_id=p_staff and a.business_date between p_from and p_to and a.status='completed') x),'[]'),
  'pos_services',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.net_total_cents line_total_cents,oi.line_total_cents gross_line_total_cents,oi.duration_minutes_snapshot service_minutes,oi.designated_client_snapshot,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=p_staff and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'product_orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.net_total_cents line_total_cents,oi.line_total_cents gross_line_total_cents,oi.duration_minutes_snapshot service_minutes,oi.designated_client_snapshot,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=p_staff and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'time_entries',coalesce((select jsonb_agg(to_jsonb(t) order by work_date,started_at) from public.spa_time_entries t where t.staff_id=p_staff and t.work_date between p_from and p_to and t.status='approved'),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o) order by work_date) from public.spa_overtime_entries o where o.staff_id=p_staff and o.work_date between p_from and p_to and o.status='approved'),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a) order by created_at) from public.spa_payroll_adjustments a where a.staff_id=p_staff and a.period_start between p_from and p_to),'[]'));
end $$;

create or replace function public.spa_report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare first_time timestamptz; last_time timestamptz;
begin
 perform spa_private.require_permission('reports.view'); if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 first_time:=p_from::timestamp at time zone 'Asia/Taipei';last_time:=(p_to+1)::timestamp at time zone 'Asia/Taipei';
 return jsonb_build_object(
 'bookings',(select count(*) from public.spa_appointments where business_date between p_from and p_to),'completed',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='cancelled'),'no_show',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='no_show'),
 'service_revenue_cents',coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0),
 'pos_revenue_cents',coalesce((select sum(total_cents) from public.spa_orders where status='paid' and paid_at>=first_time and paid_at<last_time),0),
 'revenue_cents',coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0)+coalesce((select sum(total_cents) from public.spa_orders where status='paid' and paid_at>=first_time and paid_at<last_time),0),
 'cash_in_cents',coalesce((select sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents>0),0),'cash_out_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents<0),0),'expenses_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and category='expense'),0),
 'wallet_liability_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries),0),'package_liability_cents',coalesce((select sum(p.paid_cents-coalesce((select sum(ch.revenue_cents-a.tea_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.package_id=p.id and ch.refunded_at is null),0)) from public.spa_packages p),0),
 'cash_entries',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.spa_cash_entries e where e.created_at>=first_time and e.created_at<last_time),'[]'),'daily',coalesce((select jsonb_agg(to_jsonb(d) order by d.date) from (select (e.created_at at time zone 'Asia/Taipei')::date date,sum(e.amount_cents) net_cents from public.spa_cash_entries e where e.created_at>=first_time and e.created_at<last_time group by 1) d),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'job_title_name',j.name,
  'completed',(select count(*) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed')+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'minutes',(select coalesce(sum(duration_minutes_snapshot),0) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed')+coalesce((select sum(oi.quantity*oi.duration_minutes_snapshot) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services svc on svc.id=oi.service_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'revenue_cents',(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time)+coalesce((select sum(oi.net_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'commission_cents',(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time)+coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'rating',(select round(avg(rv.rating),2) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to),'reviews',(select count(*) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to)) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null),'[]'),
 'audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (select * from public.spa_audit where created_at>=first_time and created_at<last_time order by created_at desc limit 200) a),'[]'));
end $$;

create or replace function public.spa_staff_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid; wage jsonb; wage_status text:='preview'; result jsonb;
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select staff_id into person from public.spa_roles where user_id=auth.uid() and active;
 if person is null then return jsonb_build_object('profile',null); end if;
 select x.value into wage from public.spa_payroll_runs r cross join lateral jsonb_array_elements(coalesce(r.calculation_snapshot->'rows','[]'::jsonb)) x where r.period_start=p_from and r.period_end=p_to and r.status='finalized' and x.value->>'staff_id'=person::text limit 1;
 if wage is not null then wage_status:='finalized'; else select x.value into wage from jsonb_array_elements(spa_private.payroll_preview(p_from,p_to,null)) x where x.value->>'staff_id'=person::text; end if;
 result:=jsonb_build_object(
 'profile',(select jsonb_build_object('id',s.id,'name',s.name,'title',j.name,'employment_type',e.name,'pay_basis',c.pay_basis,'base_pay_cents',c.base_pay_cents,'commission_bps',c.service_commission_bps,'product_commission_bps',c.product_commission_bps,'designated_client_bonus_bps',c.designated_client_bonus_bps,'active',s.active) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code where s.id=person),
 'lifetime_completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed')+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid'),0),
 'metrics',jsonb_build_object(
  'completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed' and business_date between p_from and p_to)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'settled_completed',(select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'unsettled_completed',(select count(*) from public.spa_appointments a where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),
  'minutes',coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to),0)+coalesce((select sum(oi.quantity*oi.duration_minutes_snapshot) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services s on s.id=oi.service_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'commission_cents',coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=person and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'rating',(select round(avg(r.rating),2) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to),'reviews',(select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to)),
 'reviews',coalesce((select jsonb_agg(to_jsonb(x)) from (select r.rating,r.comment,r.reply,r.status,r.created_at,a.reference,a.service_name from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to order by r.created_at desc limit 100) x),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s where s.staff_id=person),'[]'),'daily_shifts',coalesce((select jsonb_agg(to_jsonb(d) order by business_date) from public.spa_daily_shifts d where d.staff_id=person and d.business_date between p_from and p_to),'[]'),'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where t.staff_id=person and t.ends_at>now()-interval '7 days'),'[]'));
 return result||jsonb_build_object('profile',case when wage is null then result->'profile' else (result->'profile')||jsonb_build_object('pay_basis',wage->>'pay_basis','base_pay_cents',(wage->>'base_pay_rate_cents')::bigint,'commission_bps',(wage->>'service_commission_bps')::int,'product_commission_bps',(wage->>'product_commission_bps')::int,'designated_client_bonus_bps',(wage->>'designated_bonus_bps')::int) end,'metrics',(result->'metrics')||jsonb_build_object('commission_cents',coalesce((wage->>'service_commission_cents')::bigint,0)+coalesce((wage->>'product_commission_cents')::bigint,0)+coalesce((wage->>'designated_bonus_cents')::bigint,0),'work_minutes',coalesce((wage->>'work_minutes')::bigint,0),'total_cents',coalesce((wage->>'total_cents')::bigint,0),'payroll_status',wage_status),'payroll',wage);
end $$;

create or replace function public.spa_payroll_run_save(p_from date,p_to date,p_rule uuid,p_finalize boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v_run_id uuid; preview jsonb; actual_rule uuid:=p_rule;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_from is null or p_to is null or p_to<p_from then raise exception 'INVALID_DATE'; end if;
 perform pg_advisory_xact_lock(726005); perform pg_advisory_xact_lock(726099);
 if actual_rule is null then select id into actual_rule from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1; end if;
 if actual_rule is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 select id into v_run_id from public.spa_payroll_runs where period_start=p_from and period_end=p_to;
 if v_run_id is not null and exists(select 1 from public.spa_payroll_runs where id=v_run_id and status='finalized') then raise exception 'PAYROLL_LOCKED'; end if;
 preview:=public.spa_payroll_preview(p_from,p_to,actual_rule);
 if exists(select 1 from public.spa_payroll_runs r where r.status='finalized' and r.id is distinct from v_run_id and daterange(r.period_start,r.period_end,'[]') && daterange(p_from,p_to,'[]')) then raise exception 'PAYROLL_OVERLAP'; end if;
 if p_finalize then
  if exists(select 1 from public.spa_attendance a where a.work_date between p_from and p_to and a.status in ('open','pending')) or exists(select 1 from public.spa_attendance_requests a where a.work_date between p_from and p_to and a.status='pending') then raise exception 'PAYROLL_PENDING_ATTENDANCE'; end if;
  if exists(select 1 from public.spa_time_entries t where t.work_date between p_from and p_to and t.status='draft') then raise exception 'PAYROLL_PENDING_TIME_ENTRIES'; end if;
  if exists(select 1 from public.spa_overtime_entries o where o.work_date between p_from and p_to and o.status='draft') then raise exception 'PAYROLL_PENDING_OVERTIME'; end if;
  if exists(select 1 from jsonb_array_elements(preview) x where (x->>'unsettled_completed_count')::int>0) then raise exception 'PAYROLL_UNSETTLED_SERVICES'; end if;
  if exists(select 1 from jsonb_array_elements(preview) x where (x->>'unpriced_overtime_minutes')::bigint>0) then raise exception 'PAYROLL_OVERTIME_RATE_REQUIRED'; end if;
  if exists(select 1 from jsonb_array_elements(preview) x where not (x->>'compensation_configured')::boolean) then raise exception 'PAYROLL_COMPENSATION_REQUIRED'; end if;
 end if;
 if v_run_id is null then insert into public.spa_payroll_runs(period_start,period_end,rule_version_id,created_by) values(p_from,p_to,actual_rule,auth.uid()) returning id into v_run_id;
 else update public.spa_payroll_runs set rule_version_id=actual_rule where id=v_run_id; delete from public.spa_payroll_items where run_id=v_run_id; end if;
 insert into public.spa_payroll_items(run_id,staff_id,staff_name_snapshot,employment_type_snapshot,role_snapshot,pay_basis_snapshot,base_pay_rate_cents,commission_bps_snapshot,work_minutes,completed_count,service_count,unsettled_completed_count,refunded_service_count,service_minutes,service_sales_cents,product_order_count,product_sales_cents,designated_clients,base_cents,service_commission_cents,product_commission_cents,designated_bonus_cents,overtime_cents,bonus_cents,allowance_cents,deduction_cents,total_cents,calculation_snapshot)
 select v_run_id,x.staff_id,x.employee,x.employment_type,x.role,x.pay_basis,x.base_pay_rate_cents,x.commission_bps,x.work_minutes,x.completed_count,x.service_count,x.unsettled_completed_count,x.refunded_service_count,x.service_minutes,x.service_sales_cents,x.product_order_count,x.product_sales_cents,x.designated_clients,x.base_cents,x.service_commission_cents,x.product_commission_cents,x.designated_bonus_cents,x.overtime_cents,x.bonus_cents,x.allowance_cents,x.deduction_cents,x.total_cents,x.calculation
 from jsonb_to_recordset(preview) as x(staff_id uuid,employee text,employment_type text,role text,pay_basis text,base_pay_rate_cents bigint,commission_bps int,work_minutes int,completed_count int,service_count int,unsettled_completed_count int,refunded_service_count int,service_minutes int,service_sales_cents bigint,product_order_count int,product_sales_cents bigint,designated_clients int,base_cents bigint,service_commission_cents bigint,product_commission_cents bigint,designated_bonus_cents bigint,overtime_cents bigint,bonus_cents bigint,allowance_cents bigint,deduction_cents bigint,total_cents bigint,calculation jsonb);
 update public.spa_payroll_runs set calculation_snapshot=jsonb_build_object('rule_version_id',actual_rule,'rows',preview),needs_recalculation=false,status=case when p_finalize then 'finalized' else 'draft' end,finalized_by=case when p_finalize then auth.uid() end,finalized_at=case when p_finalize then now() end where id=v_run_id;
 perform spa_private.audit(case when p_finalize then 'payroll.finalized' else 'payroll.saved' end,v_run_id::text,jsonb_build_object('from',p_from,'to',p_to,'rule',actual_rule,'service_basis','completed_and_settled')); return v_run_id;
end $$;
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
    or not exists(select 1 from public.spa_compensation_profiles c where c.job_title_id=x.job_title_id and c.employment_type_code=x.employment_type_code)) then raise exception 'INVALID_TIER'; end if;

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
create or replace function public.spa_payroll_reopen(p_run uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726005); perform pg_advisory_xact_lock(726099);
 if length(btrim(coalesce(p_reason,'')))=0 then raise exception 'REASON_REQUIRED'; end if;
 update public.spa_payroll_runs set status='draft',needs_recalculation=true,reopened_by=auth.uid(),reopened_at=now() where id=p_run and status='finalized';
 if not found then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('payroll.reopened',p_run::text,jsonb_build_object('reason',p_reason));
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
  if qty<=0 or kind not in ('product','service') then raise exception 'INVALID_ITEM'; end if;
  if staff is not null and not exists(select 1 from public.spa_staff where id=staff and active and employment_status='active' and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
  if kind='product' then
   select * into product from public.spa_products where id=item_id and status='active' for update;
   if not found then raise exception 'INVALID_PRODUCT'; end if;
   if coalesce((select sum(delta) from public.spa_inventory_entries where product_id=product.id),0)<qty then raise exception 'INSUFFICIENT_INVENTORY'; end if;
   line:=product.price_cents*qty; subtotal:=subtotal+line;
   select coalesce(c.product_commission_bps,0) into rate from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=staff;
   commission:=case when staff is null then 0 else round(line*coalesce(rate,0)/10000.0)::bigint end;
   insert into public.spa_order_items(order_id,product_id,item_type,name_snapshot,sku_snapshot,unit_price_cents,cost_snapshot_cents,quantity,line_total_cents,staff_id,commission_cents)
   values(result.id,product.id,'product',product.name,product.sku,product.price_cents,product.cost_cents,qty,line,staff,commission);
   insert into public.spa_inventory_entries(product_id,delta,reason,reference_type,reference_id,created_by) values(product.id,-qty,'POS 銷售 '||result.reference,'order',result.id,auth.uid());
  else
   if staff is null then raise exception 'SERVICE_STAFF_REQUIRED'; end if;
   select * into service from public.spa_services where id=item_id and active and status='active';
   if not found then raise exception 'INVALID_SERVICE'; end if;
   if not exists(select 1 from public.spa_staff_services where staff_id=staff and service_id=service.id and enabled) then raise exception 'STAFF_SKILL_REQUIRED'; end if;
   line:=service.price_cents*qty; subtotal:=subtotal+line;
   select coalesce(c.service_commission_bps,0) into rate from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=staff;
   commission:=round(line*coalesce(rate,0)/10000.0)::bigint;
   insert into public.spa_order_items(order_id,service_id,item_type,name_snapshot,unit_price_cents,quantity,line_total_cents,staff_id,commission_cents)
   values(result.id,service.id,'service',service.name,service.price_cents,qty,line,staff,commission);
  end if;
 end loop;
 if p_discount>subtotal then raise exception 'INVALID_INPUT'; end if;
 update public.spa_orders set subtotal_cents=subtotal,discount_cents=p_discount,total_cents=subtotal-p_discount,status='paid',method=p_method,paid_at=now() where id=result.id returning * into result;
 if result.total_cents>0 then insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,result.total_cents,'pos',p_method,result.reference,auth.uid()); end if;
 perform spa_private.audit('order.paid',result.id::text,jsonb_build_object('reference',result.reference,'total_cents',result.total_cents,'items',jsonb_array_length(p_items))); return to_jsonb(result);
end $$;

create or replace function public.spa_checkout(p_request uuid,p_appointment uuid,p_discount bigint,p_wallet bigint,p_package uuid,p_tip bigint,p_method text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; pkg public.spa_packages; gross bigint; due bigint; balance bigint; cash bigint; revenue bigint; used int; commission bigint; result public.spa_checkouts;
begin
 perform spa_private.require_permission('pos.use'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 select * into result from public.spa_checkouts where request_id=p_request;
 if found then if result.appointment_id<>p_appointment then raise exception 'REQUEST_CONFLICT'; end if; return to_jsonb(result); end if;
 if a.status<>'completed' or exists(select 1 from public.spa_checkouts where appointment_id=a.id) then raise exception 'INVALID_TRANSITION'; end if;
 if p_discount is null or p_wallet is null or p_tip is null or p_discount<0 or p_wallet<0 or p_tip<0 or p_tip>100000000 or p_method not in ('cash','card','transfer') then raise exception 'INVALID_INPUT'; end if;
 perform 1 from public.spa_customers where id=a.customer_id for update; gross:=a.price_cents+a.tea_cents;
 if p_package is not null then
  select * into pkg from public.spa_packages where id=p_package for update;
  if not found or pkg.customer_id<>a.customer_id or pkg.service_id<>a.service_id or pkg.expires_at<=now() or p_discount<>0 then raise exception 'INVALID_PACKAGE'; end if;
  select -coalesce(sum(delta),0) into used from public.spa_package_entries where package_id=p_package;
  if used>=pkg.sessions then raise exception 'INSUFFICIENT_CREDITS'; end if;
  due:=a.tea_cents; revenue:=case when used=pkg.sessions-1 then pkg.paid_cents-coalesce((select sum(ch.revenue_cents-ap.tea_cents) from public.spa_checkouts ch join public.spa_appointments ap on ap.id=ch.appointment_id where ch.package_id=pkg.id and ch.refunded_at is null),0) else pkg.paid_cents/pkg.sessions end+a.tea_cents;
  insert into public.spa_package_entries(package_id,appointment_id,delta) values(p_package,a.id,-1);
 else
  if p_discount>gross then raise exception 'INVALID_INPUT'; end if;
  if p_discount>0 then perform spa_private.require_permission('finance.manage'); perform pg_advisory_xact_lock(726099); end if;
  due:=gross-p_discount; revenue:=due;
 end if;
 select coalesce(sum(amount_cents),0) into balance from public.spa_wallet_entries where customer_id=a.customer_id;
 if p_wallet>balance or p_wallet>due then raise exception 'INSUFFICIENT_CREDITS'; end if;
 cash:=due-p_wallet;
 if p_wallet>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,-p_wallet,'redemption',a.id,p_request,'療程結帳 '||a.reference,auth.uid()); end if;
 if cash>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,cash,'service',p_method,a.reference,auth.uid()); end if;
 if p_tip>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,p_tip,'tip',p_method,a.reference,auth.uid()); end if;
 select round(greatest(0,revenue-a.tea_cents)*commission_bps/10000.0) into commission from public.spa_staff where id=a.staff_id;
 insert into public.spa_checkouts(appointment_id,request_id,gross_cents,discount_cents,revenue_cents,cash_cents,wallet_cents,tip_cents,package_id,method,commission_cents,created_by)
 values(a.id,p_request,gross,p_discount,revenue,cash,p_wallet,p_tip,p_package,p_method,commission,auth.uid()) returning * into result;
 perform spa_private.audit('checkout.completed',a.id::text,jsonb_build_object('revenue_cents',revenue,'cash_cents',cash)); return to_jsonb(result);
end $$;

create or replace function public.spa_refund(p_request uuid,p_appointment uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; ch public.spa_checkouts;
begin
 perform spa_private.require_permission('finance.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099); select * into a from public.spa_appointments where id=p_appointment for update; select * into ch from public.spa_checkouts where appointment_id=p_appointment for update;
 if not found or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 if ch.refunded_at is not null then return; end if; perform 1 from public.spa_customers where id=a.customer_id for update;
 if ch.wallet_cents>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,ch.wallet_cents,'refund',a.id,p_request,p_reason,auth.uid()); end if;
 if ch.package_id is not null then insert into public.spa_package_entries(package_id,appointment_id,delta) values(ch.package_id,a.id,1); end if;
 if ch.cash_cents+ch.tip_cents>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,-ch.cash_cents-ch.tip_cents,'refund',ch.method,p_reason,auth.uid()); end if;
 update public.spa_checkouts set refunded_at=now(),refund_reason=p_reason where id=ch.id;
 perform spa_private.audit('checkout.refunded',a.id::text,jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.spa_time_entry_save(p_id uuid,p_staff uuid,p_work_date date,p_started_at timestamptz,p_ended_at timestamptz,p_break_minutes int,p_note text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid:=p_id; old jsonb;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726099);
 if p_staff is null or p_work_date is null or p_started_at is null or p_ended_at is null or p_ended_at<=p_started_at or p_break_minutes is null or p_break_minutes<0
  or extract(epoch from p_ended_at-p_started_at)/60-p_break_minutes<=0 or not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'INVALID_INPUT'; end if;
 if p_id is not null and exists(select 1 from public.spa_attendance where time_entry_id=p_id) then raise exception 'ATTENDANCE_LINKED_ENTRY'; end if;
 if result is null then
  insert into public.spa_time_entries(staff_id,work_date,started_at,ended_at,break_minutes,status,note,created_by)
  values(p_staff,p_work_date,p_started_at,p_ended_at,p_break_minutes,'approved',coalesce(p_note,''),auth.uid()) returning id into result;
 else
  select to_jsonb(t) into old from public.spa_time_entries t where t.id=result for update;
  if old is null then raise exception 'NOT_FOUND'; end if;
  update public.spa_time_entries set staff_id=p_staff,work_date=p_work_date,started_at=p_started_at,ended_at=p_ended_at,break_minutes=p_break_minutes,status='approved',note=coalesce(p_note,'') where id=result;
 end if;
 perform spa_private.audit('time_entry.saved',result::text,jsonb_build_object('old',old,'staff_id',p_staff,'work_date',p_work_date,'started_at',p_started_at,'ended_at',p_ended_at,'break_minutes',p_break_minutes));
 return result;
end $$;

create or replace function public.spa_time_entry_delete(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare old jsonb;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726099);
 delete from public.spa_time_entries where id=p_id returning to_jsonb(spa_time_entries) into old;
 if old is null then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('time_entry.deleted',p_id::text,old);
end $$;


revoke all on function spa_private.payroll_preview(date,date,uuid),spa_private.payroll_sale_snapshot(),spa_private.payroll_pos_allocate(),spa_private.payroll_input_guard(),spa_private.payroll_draft_changed() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
