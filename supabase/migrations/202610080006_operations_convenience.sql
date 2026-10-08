begin;

-- A read-only workbench. Every task links back to the existing protected
-- workflow, and the bed board uses exactly the appointment blocked interval.
create or replace function spa_private.operations_booking_card(a public.spa_appointments,p_owner boolean,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',a.id,'reference',a.reference,'business_date',a.business_date,
  'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,
  'customer_name',case when p_owner then c.name else left(btrim(c.name),1)||'客人' end,
  'service_name',coalesce(a.service_name_snapshot,a.service_name),
  'staff_id',s.id,'staff_name',coalesce(a.staff_name_snapshot,s.name),
  'staff_title',coalesce(j.name,s.title),'is_own',s.id=p_viewer)
 from public.spa_customers c join public.spa_staff s on s.id=a.staff_id
 left join public.spa_job_titles j on j.id=s.job_title_id where c.id=a.customer_id
$$;

create or replace function public.spa_operations_convenience() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 instant timestamptz:=now(); today date:=(now() at time zone 'Asia/Taipei')::date;
 first_date date:=today-90; last_date date:=spa_private.public_booking_last_date();
 target_month date:=(date_trunc('month',today)+interval '1 month')::date;
 owner_view boolean:=spa_private.role_name()='owner'; viewer uuid:=spa_private.current_staff_id();
 beds jsonb:='[]'::jsonb; todos jsonb:='[]'::jsonb; current_booking public.spa_appointments;
 next_booking public.spa_appointments; resource public.spa_rooms; state text; overlap_count int;
 total bigint; own_open boolean; edit_open boolean:=extract(day from today)::int<=7;
begin
 perform spa_private.require_permission('dashboard.view');
 for resource in select * from public.spa_rooms where active order by name loop
  current_booking:=null;next_booking:=null;
  select a.* into current_booking from public.spa_appointments a
   where a.room_id=resource.id and a.status in ('pending','confirmed','checked_in','in_service','completed')
   and a.starts_at<=instant and a.blocked_until>instant
   order by a.starts_at,a.id limit 1;
  select count(*) into overlap_count from public.spa_appointments a
   where a.room_id=resource.id and a.status in ('pending','confirmed','checked_in','in_service','completed')
   and a.starts_at<=instant and a.blocked_until>instant;
  select a.* into next_booking from public.spa_appointments a
   where a.room_id=resource.id and a.status in ('pending','confirmed','checked_in','in_service')
   and a.starts_at>instant and a.starts_at<=instant+interval '48 hours'
   order by a.starts_at,a.id limit 1;
  state:=case
   when current_booking.id is not null and (current_booking.status='completed' or current_booking.ends_at<=instant) then 'buffer'
   when current_booking.id is not null and current_booking.status in ('checked_in','in_service') then 'treatment'
   when current_booking.id is not null then 'reserved'
   when next_booking.id is not null and next_booking.starts_at<=instant+interval '30 minutes' then 'reserved'
   else 'free' end;
  beds:=beds||jsonb_build_array(jsonb_build_object('id',resource.id,'name',resource.name,'state',state,
   'free_at',case when current_booking.id is null then instant else current_booking.blocked_until end,
   'overlap_count',overlap_count,'current',case when current_booking.id is not null then spa_private.operations_booking_card(current_booking,owner_view,viewer) end,
   'next',case when next_booking.id is not null then spa_private.operations_booking_card(next_booking,owner_view,viewer) end));
 end loop;

 if owner_view then
  select count(*) into total from public.spa_appointments where status='pending' and business_date between first_date and last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','pending_bookings','title','預約待確認','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',last_date,'status','pending'),'description','核對技師、床位與顧客預約。'));
  select count(*) into total from public.spa_appointments where status='confirmed' and starts_at<=instant+interval '30 minutes' and business_date between first_date and today+1;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','arrivals','title','即將到店／逾時未到','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today+1,'status','confirmed','starts_before',instant+interval '30 minutes'),'description','已確認且即將開始或已逾時，尚未標記到店；請核對實際狀況。'));
  select count(*) into total from public.spa_appointments where status in ('checked_in','in_service') and ends_at<=instant and business_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','completion','title','療程結束待核對','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today,'statuses',jsonb_build_array('checked_in','in_service'),'ends_before',instant),'description','排定時間已結束，尚未確認完成；請核對實際技師。'));
  select count(*) into total from public.spa_appointments a where status='completed' and business_date between first_date and today and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','unsettled','title','已完成待結帳','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today,'status','completed','unsettled',true),'description','完成服務需結帳後才會計入薪資提成。'));
  select count(*) into total from public.spa_attendance where status='pending' and work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','attendance','title','出勤待審核','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','核准後才會寫入計薪工時。'));
  select count(*) into total from public.spa_attendance_requests where status='pending' and work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','corrections','title','補打卡／工時更正申請','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','核對申請原因與時間後審核。'));
  select count(*) into total from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open' and a.clock_in<instant-make_interval(mins=>cfg.max_shift_minutes) and a.work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','missing_clockout','title','長時間未打下班卡','count',total,'severity','urgent','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','已超過門店最長班次設定，請核對是否漏打卡。'));
  select count(*) into total from public.spa_staff_schedule_change_requests where status='pending' and requested_at>instant-interval '90 days' and business_date between first_date and last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','schedule_requests','title','班表更動待確認','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',last_date,'section','schedule-review','status','pending','requested_since',instant-interval '90 days'),'description','核准會套用正式班表，並同步預約可用時段。'));
  select count(*) into total from public.spa_staff s where s.active and s.employment_status='active' and s.archived_at is null
   and exists(select 1 from public.spa_roles r join public.spa_role_profiles p on p.code=r.role where r.staff_id=s.id and r.active and r.role<>'owner' and p.active and p.archived_at is null)
   and not exists(select 1 from public.spa_staff_schedule_submissions q where q.staff_id=s.id and q.schedule_month=target_month);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','missing_schedule','title','下月班表尚未提交','count',total,'severity',case when edit_open then 'normal' else 'urgent' end,'module','team','context',jsonb_build_object('from',target_month,'to',last_date,'section','schedule-review','target_month',target_month,'missing_submission',true),'description',case when edit_open then '員工可於本月 7 日前完成下月排班。' else '員工填班已鎖定；未交者沿用每週班表，請由店主核對。' end));
  select count(*) into total from public.spa_payroll_runs where status='draft' and needs_recalculation and period_end>=first_date and period_start<=last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','payroll_drafts','title','薪資草稿需要重算','count',total,'severity','normal','module','payroll','context',jsonb_build_object('from',first_date,'to',last_date,'section','history','status','draft','needs_recalculation',true),'description','工時、服務或制度已有更新，請在結算紀錄選取原週期重新試算。'));
  select count(*) into total from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','low_stock','title','商品低庫存','count',total,'severity','normal','module','catalog','context',jsonb_build_object('section','products'),'description','核對實際庫存，補貨後登錄庫存調整。'));
  select count(*) into total from public.spa_reviews where status='pending' and (created_at at time zone 'Asia/Taipei')::date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','reviews','title','顧客評價待審核','count',total,'severity','normal','module','reviews','context',jsonb_build_object('from',first_date,'to',today,'status','pending'),'description','審核公開內容或回覆顧客體驗。'));
 elsif viewer is not null then
  select count(*) into total from public.spa_appointments where staff_id=viewer and status in ('pending','confirmed','checked_in','in_service') and business_date between today-1 and today+1 and starts_at<=instant+interval '2 hours' and blocked_until>instant;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','my_schedule','title','我的近期服務排程','count',total,'severity','normal','module','bookings','context',jsonb_build_object('from',today-1,'to',today+1,'staff_id',viewer,'statuses',jsonb_build_array('pending','confirmed','checked_in','in_service'),'starts_before',instant+interval '2 hours','blocked_after',instant),'description','查看實際安排給您的療程；預約狀態由店主確認。'));
  select exists(select 1 from public.spa_attendance where staff_id=viewer and status='open') into own_open;
  if own_open then todos:=todos||jsonb_build_array(jsonb_build_object('key','my_clockout','title','目前上班中','count',1,'severity','normal','module','self','context',jsonb_build_object('from',today-1,'to',today,'section','my-attendance'),'description','下班時請到出勤打卡取得定位並打下班卡。')); end if;
  select count(*) into total from public.spa_attendance where staff_id=viewer and status='pending' and work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','my_attendance','title','我的出勤待審核','count',total,'severity','waiting','module','self','context',jsonb_build_object('from',first_date,'to',today,'section','my-attendance'),'description','等待店主核准後計入工時，可查看審核狀態。'));
  select count(*) into total from public.spa_staff_schedule_change_requests where staff_id=viewer and status='pending' and business_date between greatest(first_date,today-30) and last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','my_requests','title','我的班表更動待確認','count',total,'severity','waiting','module','self','context',jsonb_build_object('from',greatest(first_date,today-30),'to',last_date,'section','my-schedule','status','pending'),'description','申請尚未核准時，正式班表保持原設定。'));
  if not exists(select 1 from public.spa_staff_schedule_submissions where staff_id=viewer and schedule_month=target_month) then
   todos:=todos||jsonb_build_array(jsonb_build_object('key','my_submission','title','下月班表尚未提交','count',1,'severity',case when edit_open then 'normal' else 'waiting' end,'module','self','context',jsonb_build_object('from',target_month,'to',last_date,'section','my-schedule','target_month',target_month),'description',case when edit_open then '請於本月 7 日前完成修改並提交下月班表。' else '自助填班已鎖定；請聯絡店主核對，或提出更動申請。' end));
  end if;
 end if;
 return jsonb_build_object('server_time',instant,'today',today,'window',jsonb_build_object('from',first_date,'to',last_date),
  'target_month',target_month,'edit_open',edit_open,'is_owner',owner_view,'beds',beds,'todos',todos);
end $$;

revoke all on function spa_private.operations_booking_card(public.spa_appointments,boolean,uuid) from public,anon,authenticated;
grant execute on function spa_private.operations_booking_card(public.spa_appointments,boolean,uuid) to service_role;
revoke all on function public.spa_operations_convenience() from public,anon,authenticated;
grant execute on function public.spa_operations_convenience() to authenticated,service_role;
notify pgrst,'reload schema';
commit;
