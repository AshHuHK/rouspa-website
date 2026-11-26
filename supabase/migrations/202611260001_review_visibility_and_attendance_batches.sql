begin;

create or replace function spa_private.has_permission(p_permission text) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(spa_private.role_name()='owner' or (
  p_permission not like 'reviews.%' and exists(
   select 1 from public.spa_role_permissions rp
   where rp.role_code=spa_private.role_name() and rp.permission_code=p_permission
  )),false)
$$;

create function spa_private.attendance_period_start(p_date date) returns date
language sql immutable set search_path='' as $$
 select date_trunc('month',p_date)::date+case when extract(day from p_date)<=15 then 0 else 15 end
$$;
create function spa_private.attendance_period_end(p_date date) returns date
language sql immutable set search_path='' as $$
 select case when extract(day from p_date)<=15 then date_trunc('month',p_date)::date+14
  else (date_trunc('month',p_date)+interval '1 month - 1 day')::date end
$$;
create function spa_private.attendance_release_date(p_date date) returns date
language sql immutable set search_path='' as $$
 select spa_private.attendance_period_end(p_date)+case when extract(day from p_date)<=15 then 1 else 0 end
$$;
revoke all on function spa_private.attendance_period_start(date),spa_private.attendance_period_end(date),spa_private.attendance_release_date(date) from public,anon,authenticated;

alter function public.spa_staff_self(date,date) rename to spa_staff_self_with_reviews;
alter function public.spa_staff_self_with_reviews(date,date) set schema spa_private;
revoke all on function spa_private.spa_staff_self_with_reviews(date,date) from public,anon,authenticated;
create function public.spa_staff_self(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.spa_staff_self_with_reviews(p_from,p_to);
begin
 if spa_private.role_name()='owner' or result->'profile'='null'::jsonb then return result; end if;
 return (result-'reviews')||jsonb_build_object('metrics',(result->'metrics')-'rating'-'reviews');
end $$;
revoke all on function public.spa_staff_self(date,date) from public,anon,authenticated;
grant execute on function public.spa_staff_self(date,date) to authenticated,service_role;

alter function public.spa_ai_business_snapshot(date,date) rename to spa_ai_business_snapshot_with_reviews;
alter function public.spa_ai_business_snapshot_with_reviews(date,date) set schema spa_private;
revoke all on function spa_private.spa_ai_business_snapshot_with_reviews(date,date) from public,anon,authenticated;
create function public.spa_ai_business_snapshot(p_from date default null,p_to date default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.spa_ai_business_snapshot_with_reviews(p_from,p_to);
begin
 if spa_private.role_name()='owner' then return result; end if;
 return jsonb_set(result,'{staff}',coalesce((
  select jsonb_agg(s.value-'reviews'-'average_rating' order by s.ordinality)
  from jsonb_array_elements(result->'staff') with ordinality s
 ),'[]'));
end $$;
revoke all on function public.spa_ai_business_snapshot(date,date) from public,anon,authenticated,service_role;
grant execute on function public.spa_ai_business_snapshot(date,date) to authenticated;

create function public.spa_attendance_queue(p_from date default null,p_to date default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; first_day date; last_day date; first_month date;
 periods jsonb; source jsonb;
begin
 perform spa_private.attendance_owner();
 select least((date_trunc('month',today)-interval '11 months')::date,
  (select min(date_trunc('month',work_date)::date) from public.spa_attendance where status in ('pending','open')),
  (select min(date_trunc('month',work_date)::date) from public.spa_attendance_requests where status='pending')) into first_month;
 with candidates as (
  select (m.at_month+make_interval(days=>half.offset_days))::date as starts
  from generate_series(first_month,date_trunc('month',today),interval '1 month') m(at_month)
  cross join (values(0),(15)) half(offset_days)
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'from',starts,'to',spa_private.attendance_period_end(starts),'release_date',spa_private.attendance_release_date(starts),
  'pending_count',(select count(*) from public.spa_attendance a where a.work_date between starts and spa_private.attendance_period_end(starts) and a.status='pending'),
  'request_count',(select count(*) from public.spa_attendance_requests r where r.work_date between starts and spa_private.attendance_period_end(starts) and r.status='pending')
 ) order by starts desc),'[]') into periods from candidates where spa_private.attendance_release_date(starts)<=today;
 if p_from is not null then
  first_day:=spa_private.attendance_period_start(p_from);
  if p_from<>first_day or p_to is distinct from spa_private.attendance_period_end(first_day) then raise exception 'INVALID_DATE'; end if;
  if spa_private.attendance_release_date(first_day)>today then raise exception 'ATTENDANCE_PERIOD_NOT_READY'; end if;
 else
  if p_to is not null then raise exception 'INVALID_DATE'; end if;
  select (p->>'from')::date into first_day from jsonb_array_elements(periods) p
   where (p->>'pending_count')::int+(p->>'request_count')::int>0 order by p->>'from' limit 1;
  if first_day is null then first_day:=(periods->0->>'from')::date; end if;
 end if;
 last_day:=spa_private.attendance_period_end(first_day);
 source:=public.spa_attendance_admin(first_day,last_day);
 return source||jsonb_build_object(
  'periods',periods,'period',jsonb_build_object('from',first_day,'to',last_day,'release_date',spa_private.attendance_release_date(first_day)),
  'rows',coalesce((select jsonb_agg(a.value order by a.value->>'work_date',a.value->>'employee') from jsonb_array_elements(source->'rows') a
   where (a.value->>'work_date')::date between first_day and last_day and a.value->>'status'<>'open'),'[]'),
  'events',coalesce((select jsonb_agg(e.value) from jsonb_array_elements(source->'events') e join public.spa_attendance a on a.id=(e.value->>'attendance_id')::uuid
   where a.work_date between first_day and last_day and a.status<>'open'),'[]'),
  'breaks',coalesce((select jsonb_agg(b.value) from jsonb_array_elements(source->'breaks') b join public.spa_attendance a on a.id=(b.value->>'attendance_id')::uuid
   where a.work_date between first_day and last_day and a.status<>'open'),'[]'),
  'request_attendance',coalesce((
   select jsonb_agg(a.value) from jsonb_array_elements(source->'rows') a
   where exists(select 1 from jsonb_array_elements(source->'requests') r where r.value->>'attendance_id'=a.value->>'id' and r.value->>'status'='pending')
  ),'[]'),
  'unclosed_count',(select count(*) from public.spa_attendance a where a.work_date between first_day and last_day and a.status='open')
 );
end $$;

create function public.spa_attendance_batch_review(p_rows jsonb,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb; a public.spa_attendance; today date:=(now() at time zone 'Asia/Taipei')::date; ids uuid[]:='{}'; period_start date;
begin
 perform spa_private.attendance_owner(); perform pg_advisory_xact_lock(726099);
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 500 then raise exception 'INVALID_INPUT'; end if;
 for item in select value from jsonb_array_elements(p_rows) loop
  select * into a from public.spa_attendance where id=(item->>'id')::uuid for update;
  if a.id is null or a.status<>'pending' or a.version is distinct from (item->>'version')::int or a.id=any(ids) then raise exception 'ATTENDANCE_STALE'; end if;
  if spa_private.attendance_release_date(a.work_date)>today then raise exception 'ATTENDANCE_PERIOD_NOT_READY'; end if;
  if period_start is null then period_start:=spa_private.attendance_period_start(a.work_date);
  elsif period_start<>spa_private.attendance_period_start(a.work_date) then raise exception 'INVALID_DATE'; end if;
  if exists(select 1 from public.spa_attendance_requests r where r.attendance_id=a.id and r.status='pending') then raise exception 'ATTENDANCE_REQUEST_PENDING'; end if;
  perform public.spa_attendance_review(a.id,a.version,true,a.effective_start,a.effective_end,a.break_minutes,p_reason);
  ids:=array_append(ids,a.id);
 end loop;
 perform spa_private.audit('attendance.batch_reviewed',period_start::text,jsonb_build_object('ids',ids,'count',cardinality(ids),'reason',btrim(p_reason)));
 return jsonb_build_object('approved_count',cardinality(ids));
end $$;
revoke all on function public.spa_attendance_queue(date,date),public.spa_attendance_batch_review(jsonb,text) from public,anon,authenticated;
grant execute on function public.spa_attendance_queue(date,date),public.spa_attendance_batch_review(jsonb,text) to authenticated,service_role;

create or replace function public.spa_session() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('role',spa_private.role_name(),
 'role_name',(select p.name from public.spa_role_profiles p where p.code=spa_private.role_name()),
 'permissions',coalesce((select jsonb_agg(rp.permission_code order by rp.permission_code) from public.spa_role_permissions rp where rp.role_code=spa_private.role_name() and spa_private.has_permission(rp.permission_code)),'[]'),
 'staff_id',(select staff_id from public.spa_roles where user_id=auth.uid() and active),
 'username',(select login_name from public.spa_roles where user_id=auth.uid() and active),
 'customer_id',(select id from public.spa_customers where auth_user_id=auth.uid()))
$$;

create or replace function public.spa_operations_convenience() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare instant timestamptz:=now(); today date:=(now() at time zone 'Asia/Taipei')::date; first_date date:=today-90; last_date date:=spa_private.public_booking_last_date(); target_month date:=(date_trunc('month',today)+interval '1 month')::date; owner_view boolean:=spa_private.role_name()='owner'; viewer uuid:=spa_private.current_staff_id(); todos jsonb:='[]'::jsonb; total bigint; task jsonb; next_refresh timestamptz; revised jsonb:='[]'::jsonb; own_open boolean; edit_open boolean:=extract(day from today)::int<=7; capacity int:=(select simultaneous_capacity from public.spa_settings limit 1); current_guests int;
begin
 perform spa_private.require_permission('dashboard.view');
 select count(*) into current_guests from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service') and a.starts_at<=instant and a.ends_at>instant;
 if owner_view then
  select count(*) into total from public.spa_appointments a where a.status='pending' and a.business_date between first_date and last_date and spa_private.capacity_exceeded(a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','capacity_attention','title','超出建議容量待聯絡','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',last_date,'status','pending','capacity_attention',true),'description','預約已保留；請致電顧客協調時段，確認安排後再更新狀態。'));
  select count(*) into total from public.spa_appointments a where a.status='pending' and a.business_date between first_date and last_date and not spa_private.capacity_exceeded(a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','pending_bookings','title','預約待確認','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',last_date,'status','pending','exclude_capacity_attention',true),'description','核對技師、時段與顧客預約。'));
  select count(*) into total from public.spa_appointments where status='confirmed' and starts_at<=instant+interval '30 minutes' and business_date between first_date and today+1;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','arrivals','title','即將到店／逾時未到','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today+1,'status','confirmed','starts_before',instant+interval '30 minutes'),'description','已確認且即將開始或已逾時，尚未標記到店；請核對實際狀況。'));
  select count(*) into total from public.spa_appointments where status in ('checked_in','in_service') and ends_at<=instant and business_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','completion','title','療程結束待核對','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today,'statuses',jsonb_build_array('checked_in','in_service'),'ends_before',instant),'description','排定時間已結束，尚未確認完成；請核對實際技師。'));
  select count(*) into total from public.spa_appointments a where status='completed' and business_date between first_date and today and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id);
  todos:=todos||jsonb_build_array(jsonb_build_object('key','unsettled','title','已完成待結帳','count',total,'severity','urgent','module','bookings','context',jsonb_build_object('from',first_date,'to',today,'status','completed','unsettled',true),'description','完成服務需結帳後才會計入薪資提成。'));
  select count(*) into total from public.spa_attendance where status='pending' and work_date<=today and spa_private.attendance_release_date(work_date)<=today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','attendance','title','半月出勤待審核','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','每月 16 日及月底按半月核對，核准後計入薪資。'));
  select count(*) into total from public.spa_attendance_requests where status='pending' and work_date<=today and spa_private.attendance_release_date(work_date)<=today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','corrections','title','補打卡／工時更正申請','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','核對申請原因與時間後審核。'));
  select count(*) into total from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open' and a.clock_in<=instant-make_interval(mins=>cfg.max_shift_minutes) and a.work_date between first_date and today;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','missing_clockout','title','長時間未打下班卡','count',total,'severity','urgent','module','team','context',jsonb_build_object('from',first_date,'to',today,'section','attendance-review'),'description','已超過門店最長班次設定，請核對是否漏打卡。'));
  select count(*) into total from public.spa_staff_schedule_change_requests where status='pending' and requested_at>instant-interval '90 days' and business_date between first_date and last_date;
  todos:=todos||jsonb_build_array(jsonb_build_object('key','schedule_requests','title','班表更動待確認','count',total,'severity','normal','module','team','context',jsonb_build_object('from',first_date,'to',last_date,'section','schedule-review','status','pending','requested_since',instant-interval '90 days'),'description','核准會套用正式班表，並同步預約可用時段。'));
  select count(*) into total from public.spa_staff s where s.active and s.employment_status='active' and s.archived_at is null and exists(select 1 from public.spa_roles r join public.spa_role_profiles p on p.code=r.role where r.staff_id=s.id and r.active and r.role<>'owner' and p.active and p.archived_at is null) and not exists(select 1 from public.spa_staff_schedule_submissions q where q.staff_id=s.id and q.schedule_month=target_month);
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
  if not exists(select 1 from public.spa_staff_schedule_submissions where staff_id=viewer and schedule_month=target_month) then todos:=todos||jsonb_build_array(jsonb_build_object('key','my_submission','title','下月班表尚未提交','count',1,'severity',case when edit_open then 'normal' else 'waiting' end,'module','self','context',jsonb_build_object('from',target_month,'to',last_date,'section','my-schedule','target_month',target_month),'description',case when edit_open then '請於本月 7 日前完成修改並提交下月班表。' else '自助填班已鎖定；請聯絡店主核對，或提出更動申請。' end)); end if;
 end if;
 for task in select value from jsonb_array_elements(todos) loop revised:=revised||jsonb_build_array(task||jsonb_build_object('revision',spa_private.operations_task_revision(task->>'key',task->'context',viewer))); end loop;
 select min(boundary) into next_refresh from (select ((today+1)::timestamp at time zone 'Asia/Taipei') boundary union all select point from public.spa_appointments a cross join lateral unnest(array[a.starts_at-interval '48 hours',a.starts_at-interval '2 hours',a.starts_at-interval '30 minutes',a.starts_at,a.ends_at,a.blocked_until]) point where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.business_date between today-1 and last_date union all select a.clock_in+make_interval(mins=>cfg.max_shift_minutes) from public.spa_attendance a cross join public.spa_attendance_settings cfg where a.status='open') future where boundary>instant;
 return jsonb_build_object('next_refresh_at',next_refresh,'server_time',instant,'today',today,'window',jsonb_build_object('from',first_date,'to',last_date),'target_month',target_month,'edit_open',edit_open,'is_owner',owner_view,'capacity',jsonb_build_object('limit',capacity,'current_guests',current_guests,'currently_exceeded',current_guests>capacity,'pending_attention_count',(select count(*) from public.spa_appointments a where a.status='pending' and a.business_date between first_date and last_date and spa_private.capacity_exceeded(a.id))),'todos',revised);
end $$;

alter function public.spa_payroll_staff_detail(uuid,date,date) rename to spa_payroll_staff_detail_with_reviews;
alter function public.spa_payroll_staff_detail_with_reviews(uuid,date,date) set schema spa_private;
revoke all on function spa_private.spa_payroll_staff_detail_with_reviews(uuid,date,date) from public,anon,authenticated;
create function public.spa_payroll_staff_detail(p_staff uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.spa_payroll_staff_detail_with_reviews(p_staff,p_from,p_to);
begin
 if spa_private.role_name()='owner' then return result; end if;
 return jsonb_set(result,'{services}',coalesce((
  select jsonb_agg(s.value-'review_count' order by s.ordinality)
  from jsonb_array_elements(result->'services') with ordinality s
 ),'[]'));
end $$;
revoke all on function public.spa_payroll_staff_detail(uuid,date,date) from public,anon,authenticated;
grant execute on function public.spa_payroll_staff_detail(uuid,date,date) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
