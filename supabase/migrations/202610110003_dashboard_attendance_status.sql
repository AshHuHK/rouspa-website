begin;

-- The owner dashboard receives the roster and attendance facts required to
-- derive live arrival states.  Raw punch locations remain inside the dedicated
-- attendance review RPC and never enter this summary.
create or replace function spa_private.dashboard_attendance(p_date date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare grace int:=(select grace_minutes from public.spa_attendance_settings where id); staff_rows jsonb;
begin
 with roster as (
  select s.id staff_id,s.name staff_name,coalesce(j.name,s.title) staff_title,s.display_order,r.start_minute,r.end_minute,
   (p_date::timestamp+make_interval(mins=>r.start_minute)) at time zone 'Asia/Taipei' shift_start,
   (p_date::timestamp+make_interval(mins=>r.end_minute)) at time zone 'Asia/Taipei' shift_end
  from public.spa_staff s
  left join public.spa_job_titles j on j.id=s.job_title_id
  cross join lateral spa_private.staff_shift_window(s.id,p_date) r
  where s.active and s.employment_status='active' and s.archived_at is null and r.is_working
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'staff_id',r.staff_id,'staff_name',r.staff_name,'staff_title',r.staff_title,
  'start_minute',r.start_minute,'end_minute',r.end_minute,'shift_start',r.shift_start,'shift_end',r.shift_end,
  'attendance_count',(select count(*) from public.spa_attendance a where a.staff_id=r.staff_id and a.work_date=p_date and a.status<>'rejected'),
  'first_clock_in',(select min(coalesce(a.clock_in,a.effective_start)) from public.spa_attendance a where a.staff_id=r.staff_id and a.work_date=p_date and a.status<>'rejected'),
  'last_clock_out',(select max(coalesce(a.clock_out,a.effective_end)) from public.spa_attendance a where a.staff_id=r.staff_id and a.work_date=p_date and a.status<>'rejected'),
  'open_clock_in',(select max(a.clock_in) from public.spa_attendance a where a.staff_id=r.staff_id and a.work_date=p_date and a.status='open'),
  'time_off',coalesce((select jsonb_agg(jsonb_build_object('starts_at',o.starts_at,'ends_at',o.ends_at,'reason',o.reason) order by o.starts_at) from public.spa_time_off o where o.staff_id=r.staff_id and o.starts_at<r.shift_end and o.ends_at>r.shift_start),'[]'::jsonb)
 ) order by r.start_minute,r.display_order,r.staff_name),'[]'::jsonb) into staff_rows from roster r;
 return jsonb_build_object('server_time',now(),'grace_minutes',coalesce(grace,0),'staff',staff_rows);
end $$;

-- Preserve the existing product/POS revenue definition while adding an
-- owner-only live attendance packet.
create or replace function public.spa_dashboard() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; first_time timestamptz:=today::timestamp at time zone 'Asia/Taipei'; last_time timestamptz:=(today+1)::timestamp at time zone 'Asia/Taipei'; owner_view boolean:=spa_private.role_name()='owner'; can_manage boolean:=spa_private.has_permission('appointments.manage'); capacity int:=(select simultaneous_capacity from public.spa_settings limit 1);
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object('date',today,'appointments',(select count(*) from public.spa_appointments where business_date=today),'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',case when owner_view then coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0)+coalesce((select sum(total_cents) from public.spa_orders where status='paid' and paid_at>=first_time and paid_at<last_time),0) end,
  'unsettled_completed',case when owner_view then (select count(*) from public.spa_appointments a where a.business_date=today and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)) end,
  'staff_working',(select count(*) from public.spa_staff s join lateral spa_private.staff_shift_window(s.id,today) roster on roster.is_working where s.active and s.employment_status='active' and s.archived_at is null),
  'attendance_today',case when owner_view then spa_private.dashboard_attendance(today) end,
  'simultaneous_capacity',capacity,'capacity_attention_count',(select count(*) from public.spa_appointments a where a.business_date=today and spa_private.capacity_exceeded(a.id)),
  'new_members',case when owner_view then (select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today) end,
  'low_stock',case when owner_view then (select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold) end,
  'today_hours',(select to_jsonb(w) from spa_private.business_window(today) w),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,case when can_manage then c.name else left(btrim(c.name),1)||'小姐' end customer_name,s.name staff_name,spa_private.capacity_exceeded(a.id) capacity_exceeded from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

revoke all on function spa_private.dashboard_attendance(date) from public,anon,authenticated;
grant execute on function spa_private.dashboard_attendance(date) to service_role;
revoke all on function public.spa_dashboard() from public,anon,authenticated;
grant execute on function public.spa_dashboard() to authenticated,service_role;

notify pgrst,'reload schema';
commit;
