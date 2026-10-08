begin;

-- Opaque membership revisions detect replacement tasks without transmitting row data.
create or replace function spa_private.operations_task_revision(p_key text,p_context jsonb,p_viewer uuid) returns text
language plpgsql stable security definer set search_path='' as $$
declare result text; first_day date:=(p_context->>'from')::date; last_day date:=(p_context->>'to')::date;
begin
 if p_key in ('pending_bookings','arrivals','completion','unsettled','my_schedule') then
  select md5(coalesce(string_agg(a.id::text||a.staff_id::text||a.room_id::text||a.starts_at::text||a.ends_at::text||a.status,'|' order by a.id),'')) into result
  from public.spa_appointments a where a.business_date between first_day and last_day
   and (not(p_context?'status') or a.status=p_context->>'status')
   and (not(p_context?'statuses') or (p_context->'statuses')?a.status)
   and (not(p_context?'staff_id') or a.staff_id=(p_context->>'staff_id')::uuid)
   and (not(p_context?'starts_before') or a.starts_at<=(p_context->>'starts_before')::timestamptz)
   and (not(p_context?'ends_before') or a.ends_at<=(p_context->>'ends_before')::timestamptz)
   and (not(p_context?'blocked_after') or a.blocked_until>(p_context->>'blocked_after')::timestamptz)
   and (not coalesce((p_context->>'unsettled')::boolean,false) or not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id));
 elsif p_key in ('attendance','my_attendance','missing_clockout','my_clockout') then
  select md5(coalesce(string_agg(a.id::text||a.version::text,'|' order by a.id),'')) into result
  from public.spa_attendance a cross join public.spa_attendance_settings cfg
  where (p_key='my_clockout' or a.work_date between first_day and last_day)
   and a.status=case when p_key in ('missing_clockout','my_clockout') then 'open' else 'pending' end
   and (p_key not in ('my_attendance','my_clockout') or a.staff_id=p_viewer)
   and (p_key<>'missing_clockout' or a.clock_in<=now()-make_interval(mins=>cfg.max_shift_minutes));
 elsif p_key='corrections' then
  select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_attendance_requests where status='pending' and work_date between first_day and last_day;
 elsif p_key in ('schedule_requests','my_requests') then
  select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_staff_schedule_change_requests
  where status='pending' and business_date between first_day and last_day and (p_key<>'my_requests' or staff_id=p_viewer)
   and (not(p_context?'requested_since') or requested_at>(p_context->>'requested_since')::timestamptz);
 elsif p_key='missing_schedule' then
  select md5(coalesce(string_agg(s.id::text,'|' order by s.id),'')) into result from public.spa_staff s
  where s.active and s.employment_status='active' and s.archived_at is null
   and exists(select 1 from public.spa_roles r join public.spa_role_profiles p on p.code=r.role where r.staff_id=s.id and r.active and r.role<>'owner' and p.active and p.archived_at is null)
   and not exists(select 1 from public.spa_staff_schedule_submissions q where q.staff_id=s.id and q.schedule_month=(p_context->>'target_month')::date);
 elsif p_key='my_submission' then result:=md5(p_viewer::text||coalesce(p_context->>'target_month',''));
 elsif p_key='payroll_drafts' then
  select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_payroll_runs where status='draft' and needs_recalculation and period_end>=first_day and period_start<=last_day;
 elsif p_key='low_stock' then
  select md5(coalesce(string_agg(p.id::text||stock.n::text,'|' order by p.id),'')) into result from public.spa_products p
   cross join lateral (select coalesce(sum(i.delta),0) n from public.spa_inventory_entries i where i.product_id=p.id) stock
   where p.status='active' and stock.n<=p.low_stock_threshold;
 elsif p_key='reviews' then
  select md5(coalesce(string_agg(id::text,'|' order by id),'')) into result from public.spa_reviews where status='pending' and (created_at at time zone 'Asia/Taipei')::date between first_day and last_day;
 end if;
 return coalesce(result,md5(''));
end $$;
revoke all on function spa_private.operations_task_revision(text,jsonb,uuid) from public,anon,authenticated;

create or replace function public.spa_operations_convenience() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 instant timestamptz:=now(); today date:=(now() at time zone 'Asia/Taipei')::date;
 first_date date:=today-90; last_date date:=spa_private.public_booking_last_date();
 target_month date:=(date_trunc('month',today)+interval '1 month')::date;
 owner_view boolean:=spa_private.role_name()='owner'; viewer uuid:=spa_private.current_staff_id();
 beds jsonb:='[]'::jsonb; todos jsonb:='[]'::jsonb; current_booking public.spa_appointments;
 next_booking public.spa_appointments; resource public.spa_rooms; state text; overlap_count int;
 total bigint; task jsonb; next_refresh timestamptz; revised jsonb:='[]'::jsonb; own_open boolean; edit_open boolean:=extract(day from today)::int<=7;
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
  select count(*) into total from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open' and a.clock_in<=instant-make_interval(mins=>cfg.max_shift_minutes) and a.work_date between first_date and today;
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
 for task in select value from jsonb_array_elements(todos) loop
  revised:=revised||jsonb_build_array(task||jsonb_build_object('revision',spa_private.operations_task_revision(task->>'key',task->'context',viewer)));
 end loop;
 select min(boundary) into next_refresh from (
  select ((today+1)::timestamp at time zone 'Asia/Taipei') boundary
  union all select point from public.spa_appointments a cross join lateral unnest(array[a.starts_at-interval '48 hours',a.starts_at-interval '2 hours',a.starts_at-interval '30 minutes',a.starts_at,a.ends_at,a.blocked_until]) point
   where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.business_date between today-1 and last_date
  union all select a.clock_in+make_interval(mins=>cfg.max_shift_minutes) from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open'
 ) future where boundary>instant;
 return jsonb_build_object('next_refresh_at',next_refresh,'server_time',instant,'today',today,'window',jsonb_build_object('from',first_date,'to',last_date),
  'target_month',target_month,'edit_open',edit_open,'is_owner',owner_view,'beds',beds,'todos',revised);
end $$;

notify pgrst,'reload schema';
commit;
