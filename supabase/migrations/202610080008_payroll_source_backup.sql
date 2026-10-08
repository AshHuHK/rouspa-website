-- Preserve source packets in payroll backups; reset follows run FK cascade.
begin;

create or replace function public.spa_backup_export(p_scope text,p_from date default null,p_to date default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b record;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'INVALID_INPUT'; end if; select * into b from spa_private.reset_bounds(p_from,p_to);
 return jsonb_build_object('exported_at',now(),'scope',p_scope,'from',p_from,'to',p_to,'preview',public.spa_reset_preview(p_scope,p_from,p_to),
  'appointments',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_appointments a where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'checkouts',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(ch)) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_reviews',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_wallet_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_wallet_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_package_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_package_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_cash_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'booking_actions',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_booking_actions e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'orders',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_order_items i where i.order_id=o.id))) from public.spa_orders o where coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_inventory_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(i)) from public.spa_inventory_entries i join public.spa_orders o on o.id=i.reference_id where i.reference_type='order' and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_cash_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_orders o on o.request_id=e.request_id where e.category in ('product','pos') and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'reviews',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r where r.created_at>=b.first_time and r.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'feedback',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(f)) from public.spa_feedback f where f.created_at>=b.first_time and f.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'payroll_runs',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_payroll_items i where i.run_id=r.id))) from public.spa_payroll_runs r where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'payroll_source_snapshots',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(snap)) from public.spa_payroll_source_snapshots snap join public.spa_payroll_runs r on r.id=snap.run_id where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'time_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_time_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'overtime_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_overtime_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'payroll_adjustments',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_payroll_adjustments e where p_from is null or e.period_start between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_attendance a where p_from is null or a.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance_events',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where p_from is null or a.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance_requests',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_attendance_requests r where p_from is null or r.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'coupons',coalesce((select jsonb_agg(to_jsonb(c)) from public.spa_coupons c where (p_scope in ('appointments','all') and exists(select 1 from public.spa_appointments a where (a.id=c.appointment_id or a.id=(select appointment_id from public.spa_checkouts where id=c.checkout_id)) and (p_from is null or a.business_date between p_from and p_to))) or (p_scope in ('orders','all') and exists(select 1 from public.spa_orders o where o.id=c.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))),'[]'),
  'sale_requests',coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_sale_requests r where (p_scope in ('appointments','all') and exists(select 1 from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.id=r.checkout_id and (p_from is null or a.business_date between p_from and p_to))) or (p_scope in ('orders','all') and exists(select 1 from public.spa_orders o where o.id=r.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))),'[]'),
  'expenses',case when p_scope in ('expenses','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e where e.category='expense' and e.created_at>=b.first_time and e.created_at<b.last_time),'[]') else '[]'::jsonb end);
end $$;

-- Read-only staff navigation can identify a bed without exposing contact details.
create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare can_manage boolean:=spa_private.has_permission('appointments.manage');
begin
 perform spa_private.require_permission('appointments.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(
  (case when can_manage then to_jsonb(a) else jsonb_build_object('id',a.id,'reference',a.reference,'staff_id',a.staff_id,'room_id',a.room_id,'service_id',a.service_id,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'service_name',a.service_name_snapshot) end)
  ||jsonb_build_object('customer_name',case when can_manage then c.name else left(btrim(c.name),1)||'客人' end,'phone',case when can_manage then c.phone else null end,'therapist',s.name,'room',r.name,
   'original_staff_id',coalesce(first_change.previous_staff_id,a.staff_id),'original_therapist',coalesce(original_staff.name,s.name),'staff_change_count',(select count(*) from public.spa_appointment_staff_changes x where x.appointment_id=a.id),
   'last_reassignment_reason',case when can_manage then (select x.reason from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at desc limit 1) end,
   'checkout',case when spa_private.has_permission('finance.view') then to_jsonb(ch) else null end) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id
  left join public.spa_checkouts ch on ch.appointment_id=a.id
  left join lateral (select x.previous_staff_id from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at limit 1) first_change on true
  left join public.spa_staff original_staff on original_staff.id=first_change.previous_staff_id
  where a.business_date between p_from and p_to),'[]');
end $$;

notify pgrst,'reload schema';
commit;
