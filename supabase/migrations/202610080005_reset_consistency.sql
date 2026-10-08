-- Reset complete operational chains, including POS cash and punch evidence.
-- Review-only resets keep issued coupons to prevent duplicate rewards.
begin;

create or replace function public.spa_reset_preview(p_scope text,p_from date default null,p_to date default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b record;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'INVALID_INPUT'; end if;
 select * into b from spa_private.reset_bounds(p_from,p_to);
 return jsonb_build_object('scope',p_scope,'from',p_from,'to',p_to,'counts',jsonb_build_object(
  'appointments',case when p_scope in ('appointments','all') then (select count(*) from public.spa_appointments where p_from is null or business_date between p_from and p_to) else 0 end,
  'orders',case when p_scope in ('orders','all') then (select count(*) from public.spa_orders where coalesce(paid_at,created_at)>=b.first_time and coalesce(paid_at,created_at)<b.last_time) else 0 end,
  'reviews',case when p_scope='appointments' then (select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where p_from is null or a.business_date between p_from and p_to) when p_scope in ('reviews','all') then (select count(*) from public.spa_reviews r where (r.created_at>=b.first_time and r.created_at<b.last_time) or (p_scope='all' and exists(select 1 from public.spa_appointments a where a.id=r.appointment_id and (p_from is null or a.business_date between p_from and p_to)))) else 0 end,
  'feedback',case when p_scope in ('reviews','all') then (select count(*) from public.spa_feedback where created_at>=b.first_time and created_at<b.last_time) else 0 end,
  'payroll_runs',case when p_scope in ('payroll','all') then (select count(*) from public.spa_payroll_runs where p_from is null or (period_start<=p_to and period_end>=p_from)) else 0 end,
  'time_entries',case when p_scope in ('payroll','all') then (select count(*) from public.spa_time_entries where p_from is null or work_date between p_from and p_to)+(select count(*) from public.spa_overtime_entries where p_from is null or work_date between p_from and p_to)+(select count(*) from public.spa_payroll_adjustments where p_from is null or period_start between p_from and p_to) else 0 end,
  'attendance',case when p_scope in ('payroll','all') then (select count(*) from public.spa_attendance where p_from is null or work_date between p_from and p_to) else 0 end,
  'attendance_requests',case when p_scope in ('payroll','all') then (select count(*) from public.spa_attendance_requests where p_from is null or work_date between p_from and p_to) else 0 end,
  'expenses',case when p_scope in ('expenses','all') then (select count(*) from public.spa_cash_entries where category='expense' and created_at>=b.first_time and created_at<b.last_time) else 0 end),
  'preserved',jsonb_build_array('會員檔案與儲值／套票購買記錄（預約扣用隨預約回滾）','員工與登入帳號','療程、商品與庫存主資料','門店與系統設定'));
end $$;

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

create or replace function public.spa_reset_business_data(p_scope text,p_from date default null,p_to date default null,p_confirmation text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare b record; result jsonb; appointment_ids uuid[]; order_ids uuid[]; order_requests uuid[]; deleted_count int:=0;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_confirmation<>'RESET' or p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'RESET_CONFIRMATION_REQUIRED'; end if;
 perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099); select * into b from spa_private.reset_bounds(p_from,p_to); result:=public.spa_reset_preview(p_scope,p_from,p_to);
 if p_scope in ('payroll','all') then
  delete from public.spa_payroll_runs where p_from is null or (period_start<=p_to and period_end>=p_from);
 end if;
 if p_scope in ('appointments','all') and exists(
  select 1 from public.spa_coupons c join public.spa_appointments source on source.id=c.appointment_id
  where c.status='redeemed' and (p_from is null or source.business_date between p_from and p_to)
  and not (
   (c.checkout_id is not null and exists(select 1 from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.id=c.checkout_id and (p_from is null or a.business_date between p_from and p_to)))
   or (p_scope='all' and c.order_id is not null and exists(select 1 from public.spa_orders o where o.id=c.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))
  )
 ) then raise exception 'RESET_COUPON_IN_USE'; end if;
 if p_scope in ('orders','all') then
  select coalesce(array_agg(id),'{}'::uuid[]),coalesce(array_agg(request_id),'{}'::uuid[]) into order_ids,order_requests from public.spa_orders where coalesce(paid_at,created_at)>=b.first_time and coalesce(paid_at,created_at)<b.last_time;
  delete from public.spa_inventory_entries where reference_type='order' and reference_id=any(order_ids); delete from public.spa_cash_entries where category in ('product','pos') and request_id=any(order_requests); delete from public.spa_orders where id=any(order_ids);
 end if;
 if p_scope in ('appointments','all') then
  select coalesce(array_agg(id),'{}'::uuid[]) into appointment_ids from public.spa_appointments where p_from is null or business_date between p_from and p_to;
  if pg_catalog.to_regclass('public.spa_legacy_imports') is not null then execute 'update public.spa_legacy_imports set appointment_id=null where appointment_id=any($1)' using appointment_ids; end if;
  delete from public.spa_booking_actions where appointment_id=any(appointment_ids); delete from public.spa_booking_access where appointment_id=any(appointment_ids);
  delete from public.spa_reviews where appointment_id=any(appointment_ids); delete from public.spa_package_entries where appointment_id=any(appointment_ids);
  delete from public.spa_wallet_entries where appointment_id=any(appointment_ids); delete from public.spa_cash_entries where appointment_id=any(appointment_ids);
  delete from public.spa_checkouts where appointment_id=any(appointment_ids); delete from public.spa_appointments where id=any(appointment_ids); get diagnostics deleted_count=row_count;
 end if;
 if p_scope in ('reviews','all') then delete from public.spa_reviews where created_at>=b.first_time and created_at<b.last_time; end if;
 if p_scope in ('reviews','all') then delete from public.spa_feedback where created_at>=b.first_time and created_at<b.last_time; end if;
 if p_scope in ('payroll','all') then
  delete from public.spa_attendance_requests where p_from is null or work_date between p_from and p_to;
  delete from public.spa_attendance where p_from is null or work_date between p_from and p_to;
  delete from public.spa_time_entries where p_from is null or work_date between p_from and p_to;
  delete from public.spa_overtime_entries where p_from is null or work_date between p_from and p_to; delete from public.spa_payroll_adjustments where p_from is null or period_start between p_from and p_to;
 end if;
 if p_scope in ('expenses','all') then delete from public.spa_cash_entries where category='expense' and created_at>=b.first_time and created_at<b.last_time; end if;
 perform spa_private.audit('business_data.reset',p_scope,jsonb_build_object('from',p_from,'to',p_to,'preview',result)); return result||jsonb_build_object('reset_at',now());
end $$;

notify pgrst,'reload schema';
commit;
