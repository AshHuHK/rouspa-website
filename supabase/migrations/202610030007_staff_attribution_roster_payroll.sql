begin;

-- A dated roster overrides the weekly template. It is the final source used by
-- website availability, customer rescheduling and the admin booking engine.
create table if not exists public.spa_daily_shifts (
 id uuid primary key default gen_random_uuid(),
 staff_id uuid not null references public.spa_staff,
 business_date date not null,
 is_working boolean not null default true,
 start_minute int not null default 600,
 end_minute int not null default 1560,
 note text not null default '',
 updated_by uuid references auth.users,
 updated_at timestamptz not null default now(),
 unique(staff_id,business_date),
 check(start_minute>=0 and end_minute>start_minute and end_minute<=2880),
 check(length(note)<=500)
);
create index if not exists spa_daily_shifts_date on public.spa_daily_shifts(business_date,staff_id);
alter table public.spa_daily_shifts enable row level security;
revoke all on public.spa_daily_shifts from public,anon,authenticated;
grant all on public.spa_daily_shifts to service_role;

create or replace function spa_private.staff_shift_window(p_staff uuid,p_date date)
returns table(is_working boolean,start_minute int,end_minute int,source text,note text)
language sql stable security definer set search_path='' as $$
 select coalesce(d.is_working,w.staff_id is not null),coalesce(d.start_minute,w.start_minute),coalesce(d.end_minute,w.end_minute),
  case when d.id is not null then 'daily' when w.staff_id is not null then 'weekly' else 'none' end,coalesce(d.note,'')
 from (select 1) seed
 left join public.spa_daily_shifts d on d.staff_id=p_staff and d.business_date=p_date
 left join public.spa_shifts w on w.staff_id=p_staff and w.weekday=extract(dow from p_date)::int
$$;

create or replace function spa_private.candidates(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings), hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes) finish,p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s)
 select st.id,r.id,t.finish,t.blocked from public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
 cross join public.spa_rooms r cross join cfg cross join hours h cross join timing t
 where h.is_open and st.active and st.archived_at is null and st.is_bookable and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
 and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed') and (a.staff_id=st.id or a.room_id=r.id) and a.starts_at<t.blocked and a.blocked_until>p_start)
 order by (select count(*) from public.spa_appointments a where a.staff_id=st.id and a.business_date=p_date and a.status not in ('cancelled','no_show')),st.display_order,r.name
$$;

create or replace function spa_private.customer_candidates(p_id uuid,p_date date,p_start timestamptz,p_staff uuid)
returns table(staff_id uuid,room_id uuid,ends_at timestamptz,blocked_until timestamptz)
language sql stable security definer set search_path='' as $$
 select st.id,r.id,p_start+(a.ends_at-a.starts_at),p_start+(a.blocked_until-a.starts_at)
 from public.spa_appointments a join public.spa_services svc on svc.id=a.service_id and svc.active and svc.status='active' and svc.online_booking_enabled
 cross join public.spa_settings cfg cross join spa_private.business_window(p_date) h cross join public.spa_staff st
 join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=a.service_id and sk.enabled
 join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working cross join public.spa_rooms r
 where a.id=p_id and h.is_open and st.active and st.archived_at is null and st.is_bookable and r.active and (p_staff is null or st.id=p_staff)
 and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
 and p_start+(a.blocked_until-a.starts_at)<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
 and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<p_start+(a.blocked_until-a.starts_at) and o.ends_at>p_start)
 and not exists(select 1 from public.spa_appointments other where other.id<>a.id and other.status in ('pending','confirmed','checked_in','in_service','completed') and (other.staff_id=st.id or other.room_id=r.id) and other.starts_at<p_start+(a.blocked_until-a.starts_at) and other.blocked_until>p_start)
 order by (select count(*) from public.spa_appointments b where b.staff_id=st.id and b.business_date=p_date and b.id<>a.id and b.status not in ('cancelled','no_show')),st.display_order,r.name
$$;

create or replace function public.spa_daily_shift_save(p_staff uuid,p_date date,p_is_working boolean,p_start int,p_end int,p_note text default '')
returns void language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; range_start timestamptz; range_end timestamptz;
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001);
 if p_date is null or p_is_working is null or p_start<0 or p_end<=p_start or p_end>2880 or length(coalesce(p_note,''))>500 then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and active and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 select * into cfg from public.spa_settings;
 range_start:=(p_date::timestamp+make_interval(mins=>p_start)) at time zone cfg.timezone;
 range_end:=(p_date::timestamp+make_interval(mins=>p_end)) at time zone cfg.timezone;
 if exists(select 1 from public.spa_appointments a where a.staff_id=p_staff and a.business_date=p_date and a.status in ('pending','confirmed','checked_in','in_service')
  and (not p_is_working or a.starts_at<range_start or a.blocked_until>range_end)) then raise exception 'EXISTING_BOOKINGS'; end if;
 insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
 values(p_staff,p_date,p_is_working,p_start,p_end,btrim(coalesce(p_note,'')),auth.uid(),now())
 on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 perform spa_private.audit('daily_shift.saved',p_staff::text,jsonb_build_object('date',p_date,'working',p_is_working,'start',p_start,'end',p_end,'note',p_note));
end $$;

create or replace function public.spa_daily_shift_delete(p_staff uuid,p_date date)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.manage');
 delete from public.spa_daily_shifts where staff_id=p_staff and business_date=p_date;
 if not found then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('daily_shift.deleted',p_staff::text,jsonb_build_object('date',p_date));
end $$;

-- The current appointment staff_id is the actual service provider. Every
-- correction is recorded so the originally requested therapist is retained.
create table if not exists public.spa_appointment_staff_changes (
 id uuid primary key default gen_random_uuid(),
 appointment_id uuid not null references public.spa_appointments on delete cascade,
 previous_staff_id uuid not null references public.spa_staff,
 new_staff_id uuid not null references public.spa_staff,
 reason text not null,
 previous_commission_cents bigint,
 new_commission_cents bigint,
 changed_by uuid not null references auth.users,
 changed_at timestamptz not null default now(),
 check(previous_staff_id<>new_staff_id),
 check(length(btrim(reason)) between 1 and 1000)
);
create index if not exists spa_staff_changes_appointment on public.spa_appointment_staff_changes(appointment_id,changed_at);
alter table public.spa_appointment_staff_changes enable row level security;
revoke all on public.spa_appointment_staff_changes from public,anon,authenticated;
grant all on public.spa_appointment_staff_changes to service_role;

create or replace function spa_private.checkout_commission_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare rate int; tea bigint;
begin
 select coalesce(sk.commission_override_bps,s.commission_bps),a.tea_cents into rate,tea
 from public.spa_appointments a join public.spa_staff s on s.id=a.staff_id
 left join public.spa_staff_services sk on sk.staff_id=a.staff_id and sk.service_id=a.service_id and sk.enabled
 where a.id=new.appointment_id;
 if rate is null then raise exception 'STAFF_SKILL_REQUIRED'; end if;
 new.commission_cents:=round(greatest(0,new.revenue_cents-tea)*rate/10000.0);
 return new;
end $$;
drop trigger if exists spa_checkout_commission_guard on public.spa_checkouts;
create trigger spa_checkout_commission_guard before insert or update of appointment_id,revenue_cents on public.spa_checkouts
for each row execute function spa_private.checkout_commission_guard();

create or replace function public.spa_appointment_reassign(p_appointment uuid,p_staff uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; old_staff public.spa_staff; new_staff public.spa_staff; roster record; cfg public.spa_settings; old_commission bigint; new_commission bigint; has_review boolean;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed','checked_in','in_service','completed') then raise exception 'INVALID_TRANSITION'; end if;
 if p_staff=a.staff_id then raise exception 'SAME_STAFF'; end if;
 if length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 select * into old_staff from public.spa_staff where id=a.staff_id;
 select * into new_staff from public.spa_staff where id=p_staff and active and archived_at is null;
 if not found then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if not exists(select 1 from public.spa_staff_services where staff_id=p_staff and service_id=a.service_id and enabled) then raise exception 'STAFF_SKILL_REQUIRED'; end if;
 if a.status<>'completed' then
  select * into roster from spa_private.staff_shift_window(p_staff,a.business_date);
  select * into cfg from public.spa_settings;
  if not coalesce(roster.is_working,false)
   or a.starts_at<((a.business_date::timestamp+make_interval(mins=>roster.start_minute)) at time zone cfg.timezone)
   or a.blocked_until>((a.business_date::timestamp+make_interval(mins=>roster.end_minute)) at time zone cfg.timezone)
   or exists(select 1 from public.spa_time_off o where o.staff_id=p_staff and o.starts_at<a.blocked_until and o.ends_at>a.starts_at)
   or exists(select 1 from public.spa_appointments other where other.id<>a.id and other.staff_id=p_staff and other.status in ('pending','confirmed','checked_in','in_service','completed') and other.starts_at<a.blocked_until and other.blocked_until>a.starts_at)
  then raise exception 'STAFF_NOT_AVAILABLE'; end if;
 end if;
 select commission_cents into old_commission from public.spa_checkouts where appointment_id=a.id;
 update public.spa_appointments set staff_id=p_staff,staff_name_snapshot=new_staff.name where id=a.id;
 update public.spa_checkouts ch set commission_cents=round(greatest(0,ch.revenue_cents-a.tea_cents)*coalesce(sk.commission_override_bps,new_staff.commission_bps)/10000.0)
 from public.spa_staff_services sk where ch.appointment_id=a.id and sk.staff_id=p_staff and sk.service_id=a.service_id and sk.enabled;
 select commission_cents into new_commission from public.spa_checkouts where appointment_id=a.id;
 select exists(select 1 from public.spa_reviews where appointment_id=a.id) into has_review;
 insert into public.spa_appointment_staff_changes(appointment_id,previous_staff_id,new_staff_id,reason,previous_commission_cents,new_commission_cents,changed_by)
 values(a.id,a.staff_id,p_staff,btrim(p_reason),old_commission,new_commission,auth.uid());
 perform spa_private.audit('appointment.staff_reassigned',a.id::text,jsonb_build_object('previous_staff_id',a.staff_id,'previous_staff',old_staff.name,'new_staff_id',p_staff,'new_staff',new_staff.name,'reason',p_reason,'review_reassigned',has_review,'previous_commission_cents',old_commission,'new_commission_cents',new_commission));
 return jsonb_build_object('appointment_id',a.id,'previous_staff',old_staff.name,'actual_staff',new_staff.name,'review_reassigned',has_review,'commission_cents',new_commission);
end $$;

create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare can_manage boolean:=spa_private.has_permission('appointments.manage');
begin
 perform spa_private.require_permission('appointments.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(
  (case when can_manage then to_jsonb(a) else jsonb_build_object('id',a.id,'reference',a.reference,'staff_id',a.staff_id,'service_id',a.service_id,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'service_name',a.service_name_snapshot) end)
  ||jsonb_build_object('customer_name',c.name,'phone',case when can_manage then c.phone else null end,'therapist',s.name,'room',r.name,
   'original_staff_id',coalesce(first_change.previous_staff_id,a.staff_id),'original_therapist',coalesce(original_staff.name,s.name),'staff_change_count',(select count(*) from public.spa_appointment_staff_changes x where x.appointment_id=a.id),
   'last_reassignment_reason',case when can_manage then (select x.reason from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at desc limit 1) end,
   'checkout',case when spa_private.has_permission('finance.view') then to_jsonb(ch) else null end) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id
  left join public.spa_checkouts ch on ch.appointment_id=a.id
  left join lateral (select x.previous_staff_id from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at limit 1) first_change on true
  left join public.spa_staff original_staff on original_staff.id=first_change.previous_staff_id
  where a.business_date between p_from and p_to),'[]');
end $$;

-- Payroll rows now come from the same personnel record and actual appointment
-- staff_id. Only completed, non-refunded checkouts create payable service count.
alter table public.spa_payroll_items add column if not exists staff_name_snapshot text not null default '';
alter table public.spa_payroll_items add column if not exists pay_basis_snapshot text not null default 'monthly';
alter table public.spa_payroll_items add column if not exists base_pay_rate_cents bigint not null default 0;
alter table public.spa_payroll_items add column if not exists commission_bps_snapshot int not null default 0;
alter table public.spa_payroll_items add column if not exists service_count int not null default 0;
alter table public.spa_payroll_items add column if not exists completed_count int not null default 0;
alter table public.spa_payroll_items add column if not exists unsettled_completed_count int not null default 0;
alter table public.spa_payroll_items add column if not exists refunded_service_count int not null default 0;
alter table public.spa_payroll_items add column if not exists product_order_count int not null default 0;

create or replace function public.spa_payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 if version.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 return coalesce((
 with staff_metrics as (
  select s.id,s.name,s.title,s.employment_type_code,s.pay_basis,coalesce(s.base_pay_cents,0) base_pay_cents,s.commission_bps,
   coalesce((select sum(greatest(0,(extract(epoch from te.ended_at-te.started_at)/60)::int-te.break_minutes)) from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved'),0)::bigint work_minutes,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint service_count,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),0)::bigint unsettled_completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is not null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint refunded_service_count,
   coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint service_minutes,
   coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)::bigint service_sales_cents,
   coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)::bigint checkout_commission_cents,
   coalesce((select count(distinct o.id) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_order_count,
   coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_sales_cents,
   coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint checkout_product_commission_cents,
   coalesce((select count(*) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and c.preferred_staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint designated_clients,
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint deduction_cents,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_minutes
  from public.spa_staff s where coalesce(s.hire_date,s.created_at::date)<=p_to
 ), commission as (
  select m.*,coalesce((select round(m.service_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t
    where t.rule_version_id=version.id and t.metric in ('service_minutes','service_count','service_sales_cents') and ((t.metric='service_minutes' and m.service_minutes>=t.threshold_from and (t.threshold_to is null or m.service_minutes<t.threshold_to))
      or (t.metric='service_count' and m.service_count>=t.threshold_from and (t.threshold_to is null or m.service_count<t.threshold_to))
      or (t.metric='service_sales_cents' and m.service_sales_cents>=t.threshold_from and (t.threshold_to is null or m.service_sales_cents<t.threshold_to)))
    order by t.threshold_from desc limit 1),m.checkout_commission_cents) service_commission_cents,
   coalesce((select round(m.product_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t
    where t.rule_version_id=version.id and t.metric='product_sales_cents' and m.product_sales_cents>=t.threshold_from and (t.threshold_to is null or m.product_sales_cents<t.threshold_to)
    order by t.threshold_from desc limit 1),m.checkout_product_commission_cents) product_commission_cents
  from staff_metrics m
 ), base_calc as (
  select c.*,case when c.pay_basis='monthly' then c.base_pay_cents when c.pay_basis='hourly' then round(c.base_pay_cents*c.work_minutes/60.0)::bigint else c.base_pay_cents*c.service_count end base_cents
  from commission c
 ), overtime_calc as (
  select b.*,coalesce((select round(sum((case when b.pay_basis='monthly' then (b.base_pay_cents+case when version.include_regular_commission then b.service_commission_cents+b.designated_bonus_cents else 0 end)/version.hourly_divisor::numeric when b.pay_basis='hourly' then b.base_pay_cents::numeric else 0 end)*greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint
   from public.spa_overtime_entries o join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type where o.staff_id=b.id and o.work_date between p_from and p_to and o.status='approved' and o.minutes>r.start_minute),0) overtime_cents
  from base_calc b
 )
 select jsonb_agg(jsonb_build_object(
  'staff_id',id,'employee',name,'role',title,'employment_type',employment_type_code,'pay_basis',pay_basis,'base_pay_rate_cents',base_pay_cents,'commission_bps',commission_bps,
  'work_minutes',work_minutes,'completed_count',completed_count,'service_count',service_count,'unsettled_completed_count',unsettled_completed_count,'refunded_service_count',refunded_service_count,'service_minutes',service_minutes,
  'service_sales_cents',service_sales_cents,'product_order_count',product_order_count,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'overtime_minutes',overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',service_commission_cents,'product_commission_cents',product_commission_cents,'designated_bonus_cents',designated_bonus_cents,
  'overtime_cents',overtime_cents,'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,
  'total_cents',greatest(0,base_cents+service_commission_cents+product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'overtime_warning',case when overtime_minutes>version.agreed_monthly_limit_minutes then '超過每月 54 小時上限' when overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般每月 46 小時上限' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission,'service_basis','completed_and_settled','staff_source','spa_staff','attribution_source','spa_appointments.staff_id')) order by name)
 from overtime_calc),'[]');
end $$;

create or replace function public.spa_payroll_staff_detail(p_staff uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'NOT_FOUND'; end if;
 return jsonb_build_object(
  'profile',(select to_jsonb(s) from public.spa_staff s where s.id=p_staff),
  'services',coalesce((select jsonb_agg(to_jsonb(x) order by x.business_date,x.starts_at) from (
   select a.id,a.reference,a.business_date,a.starts_at,a.service_name_snapshot service_name,a.duration_minutes_snapshot service_minutes,
    case when ch.id is null then 'unsettled' when ch.refunded_at is not null then 'refunded' else 'settled' end settlement_status,
    ch.revenue_cents,ch.commission_cents,(select count(*) from public.spa_reviews r where r.appointment_id=a.id) review_count
   from public.spa_appointments a left join public.spa_checkouts ch on ch.appointment_id=a.id
   where a.staff_id=p_staff and a.business_date between p_from and p_to and a.status='completed') x),'[]'),
  'product_orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (
   select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.line_total_cents,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id
   where oi.staff_id=p_staff and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o) order by work_date) from public.spa_overtime_entries o where o.staff_id=p_staff and o.work_date between p_from and p_to and o.status='approved'),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a) order by created_at) from public.spa_payroll_adjustments a where a.staff_id=p_staff and a.period_start=p_from),'[]'));
end $$;

create or replace function public.spa_payroll_run_save(p_from date,p_to date,p_rule uuid,p_finalize boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v_run_id uuid; preview jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_from is null or p_to is null or p_to<p_from then raise exception 'INVALID_DATE'; end if;
 perform pg_advisory_xact_lock(726005);
 select id into v_run_id from public.spa_payroll_runs where period_start=p_from and period_end=p_to;
 if v_run_id is not null and exists(select 1 from public.spa_payroll_runs where id=v_run_id and status='finalized') then raise exception 'PAYROLL_LOCKED'; end if;
 preview:=public.spa_payroll_preview(p_from,p_to,p_rule);
 if v_run_id is null then insert into public.spa_payroll_runs(period_start,period_end,rule_version_id,created_by) values(p_from,p_to,p_rule,auth.uid()) returning id into v_run_id;
 else update public.spa_payroll_runs set rule_version_id=p_rule where id=v_run_id; delete from public.spa_payroll_items where run_id=v_run_id; end if;
 insert into public.spa_payroll_items(run_id,staff_id,staff_name_snapshot,employment_type_snapshot,role_snapshot,pay_basis_snapshot,base_pay_rate_cents,commission_bps_snapshot,work_minutes,completed_count,service_count,unsettled_completed_count,refunded_service_count,service_minutes,service_sales_cents,product_order_count,product_sales_cents,designated_clients,base_cents,service_commission_cents,product_commission_cents,designated_bonus_cents,overtime_cents,bonus_cents,allowance_cents,deduction_cents,total_cents,calculation_snapshot)
 select v_run_id,x.staff_id,x.employee,x.employment_type,x.role,x.pay_basis,x.base_pay_rate_cents,x.commission_bps,x.work_minutes,x.completed_count,x.service_count,x.unsettled_completed_count,x.refunded_service_count,x.service_minutes,x.service_sales_cents,x.product_order_count,x.product_sales_cents,x.designated_clients,x.base_cents,x.service_commission_cents,x.product_commission_cents,x.designated_bonus_cents,x.overtime_cents,x.bonus_cents,x.allowance_cents,x.deduction_cents,x.total_cents,x.calculation
 from jsonb_to_recordset(preview) as x(staff_id uuid,employee text,employment_type text,role text,pay_basis text,base_pay_rate_cents bigint,commission_bps int,work_minutes int,completed_count int,service_count int,unsettled_completed_count int,refunded_service_count int,service_minutes int,service_sales_cents bigint,product_order_count int,product_sales_cents bigint,designated_clients int,base_cents bigint,service_commission_cents bigint,product_commission_cents bigint,designated_bonus_cents bigint,overtime_cents bigint,bonus_cents bigint,allowance_cents bigint,deduction_cents bigint,total_cents bigint,calculation jsonb);
 update public.spa_payroll_runs set calculation_snapshot=jsonb_build_object('rule_version_id',p_rule,'rows',preview),status=case when p_finalize then 'finalized' else 'draft' end,finalized_by=case when p_finalize then auth.uid() end,finalized_at=case when p_finalize then now() end where id=v_run_id;
 perform spa_private.audit(case when p_finalize then 'payroll.finalized' else 'payroll.saved' end,v_run_id::text,jsonb_build_object('from',p_from,'to',p_to,'rule',p_rule,'service_basis','completed_and_settled')); return v_run_id;
end $$;

create or replace function public.spa_overtime_save(p_staff uuid,p_date date,p_type text,p_minutes int,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_staff where id=p_staff and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_type not in ('weekday','rest_day','national_holiday','regular_holiday') or p_minutes not between 1 and 720 or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_overtime_entries(staff_id,work_date,overtime_type,minutes,reason,created_by) values(p_staff,p_date,p_type,p_minutes,btrim(p_reason),auth.uid()) returning id into result;
 perform spa_private.audit('overtime.created',result::text,jsonb_build_object('staff_id',p_staff,'date',p_date,'type',p_type,'minutes',p_minutes)); return result;
end $$;

create or replace function public.spa_payroll_adjustment_save(p_staff uuid,p_period date,p_kind text,p_cents bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_staff where id=p_staff and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_kind not in ('bonus','allowance','deduction','designated_bonus') or p_cents<0 or length(btrim(coalesce(p_note,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_payroll_adjustments(staff_id,period_start,kind,amount_cents,note,created_by) values(p_staff,p_period,p_kind,p_cents,btrim(p_note),auth.uid()) returning id into result;
 perform spa_private.audit('payroll.adjustment_created',result::text,jsonb_build_object('staff_id',p_staff,'period',p_period,'kind',p_kind,'cents',p_cents)); return result;
end $$;

create or replace function public.spa_team_os() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.view');
 return jsonb_build_object(
  'staff',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('employment_type_name',e.name,'job_title_name',j.name) order by s.display_order,s.created_at) from public.spa_staff s left join public.spa_employment_types e on e.code=s.employment_type_code left join public.spa_job_titles j on j.id=s.job_title_id),'[]'),
  'employment_types',coalesce((select jsonb_agg(to_jsonb(e) order by display_order) from public.spa_employment_types e),'[]'),
  'job_titles',coalesce((select jsonb_agg(to_jsonb(j) order by display_order) from public.spa_job_titles j),'[]'),
  'role_profiles',coalesce((select jsonb_agg(to_jsonb(r) order by display_order) from public.spa_role_profiles r),'[]'),
  'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s),'[]'),
  'daily_shifts',coalesce((select jsonb_agg(to_jsonb(d) order by business_date,staff_id) from public.spa_daily_shifts d where d.business_date>=(now() at time zone 'Asia/Taipei')::date-7 and d.business_date<=(now() at time zone 'Asia/Taipei')::date+366),'[]'),
  'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where ends_at>now()-interval '30 days'),'[]'),
  'accounts',case when spa_private.has_permission('team.manage') then coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'role',r.role,'staff_id',r.staff_id,'active',r.active,'username',r.login_name,'email',case when r.role='owner' then u.email end)) from public.spa_roles r join auth.users u on u.id=r.user_id),'[]') else '[]'::jsonb end);
end $$;

create or replace function public.spa_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; owner_view boolean:=spa_private.role_name()='owner';
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object('date',today,'appointments',(select count(*) from public.spa_appointments where business_date=today),'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',case when owner_view then coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.business_date=today and ch.refunded_at is null),0) end,
  'staff_working',(select count(*) from public.spa_staff s join lateral spa_private.staff_shift_window(s.id,today) roster on roster.is_working where s.active and s.archived_at is null),
  'rooms_active',(select count(*) from public.spa_rooms where active),'new_members',case when owner_view then (select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today) end,
  'low_stock',case when owner_view then (select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold) end,
  'today_hours',(select to_jsonb(w) from spa_private.business_window(today) w),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,c.name customer_name,s.name staff_name,r.name resource_name from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

create or replace function public.spa_staff_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid;
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select staff_id into person from public.spa_roles where user_id=auth.uid() and active;
 if person is null then return jsonb_build_object('profile',null); end if;
 return jsonb_build_object('profile',(select jsonb_build_object('id',s.id,'name',s.name,'title',s.title,'pay_basis',s.pay_basis,'base_pay_cents',s.base_pay_cents,'commission_bps',s.commission_bps,'active',s.active) from public.spa_staff s where s.id=person),
 'lifetime_completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed'),
 'metrics',jsonb_build_object('completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed' and business_date between p_from and p_to),
 'settled_completed',(select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to),
 'unsettled_completed',(select count(*) from public.spa_appointments a where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),
 'minutes',coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to),0),
 'commission_cents',coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=person and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0),
 'rating',(select round(avg(r.rating),2) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to),
 'reviews',(select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to)),
 'reviews',coalesce((select jsonb_agg(to_jsonb(x)) from (select r.rating,r.comment,r.reply,r.status,r.created_at,a.reference,a.service_name from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to order by r.created_at desc limit 100) x),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s where s.staff_id=person),'[]'),
 'daily_shifts',coalesce((select jsonb_agg(to_jsonb(d) order by business_date) from public.spa_daily_shifts d where d.staff_id=person and d.business_date between p_from and p_to),'[]'),
 'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where t.staff_id=person and t.ends_at>now()-interval '7 days'),'[]'));
end $$;

revoke all on function public.spa_daily_shift_save(uuid,date,boolean,int,int,text),public.spa_daily_shift_delete(uuid,date),public.spa_appointment_reassign(uuid,uuid,text),public.spa_payroll_staff_detail(uuid,date,date) from public,anon,authenticated;
grant execute on function public.spa_daily_shift_save(uuid,date,boolean,int,int,text),public.spa_daily_shift_delete(uuid,date),public.spa_appointment_reassign(uuid,uuid,text),public.spa_payroll_staff_detail(uuid,date,date) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
