begin;

-- One-time punch locations, not continuous tracking. No anonymous/table access.
create table if not exists public.spa_attendance_settings (
 id boolean primary key default true check(id), latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180), address text not null,
 radius_m int not null default 100 check(radius_m between 20 and 2000),
 max_accuracy_m int not null default 50 check(max_accuracy_m between 5 and 500),
 grace_minutes int not null default 5 check(grace_minutes between 0 and 60),
 max_shift_minutes int not null default 1440 check(max_shift_minutes between 60 and 2880),
 updated_at timestamptz not null default now(), updated_by uuid references auth.users
);
-- Exact place marker (!3d/!4d), not the map's camera centre (@ coordinates).
-- Same address used by the existing public map: Lanjing St 421, Chiayi.
insert into public.spa_attendance_settings(id,latitude,longitude,address)
values(true,23.4768128,120.4431785,'嘉義市西區蘭井街421號') on conflict(id) do nothing;

create table if not exists public.spa_attendance (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.spa_staff,
 work_date date not null, clock_in timestamptz, clock_out timestamptz,
 shift_start timestamptz, shift_end timestamptz, grace_minutes int not null default 5,
 effective_start timestamptz, effective_end timestamptz, break_minutes int not null default 0 check(break_minutes>=0),
 status text not null default 'open' check(status in ('open','pending','approved','rejected')),
 flags text[] not null default '{}', time_entry_id uuid unique references public.spa_time_entries on delete set null,
 review_note text not null default '', reviewed_by uuid references auth.users, reviewed_at timestamptz,
 version int not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(clock_out is null or clock_out>=clock_in), check(effective_end is null or effective_end>effective_start)
);
create unique index if not exists spa_attendance_one_open on public.spa_attendance(staff_id) where status='open';
create index if not exists spa_attendance_date on public.spa_attendance(work_date,staff_id);
create table if not exists public.spa_attendance_events (
 id uuid primary key default gen_random_uuid(), request_id uuid not null unique,
 attendance_id uuid not null references public.spa_attendance on delete cascade, staff_id uuid not null references public.spa_staff,
 kind text not null check(kind in ('in','out')), recorded_at timestamptz not null default now(),
 latitude double precision, longitude double precision, accuracy_m double precision, distance_m double precision,
 flags text[] not null default '{}', reason text not null default '', location_error text not null default '',
 geofence_snapshot jsonb not null, created_by uuid not null references auth.users
);
create table if not exists public.spa_attendance_requests (
 id uuid primary key default gen_random_uuid(), request_id uuid not null unique, staff_id uuid not null references public.spa_staff,
 attendance_id uuid references public.spa_attendance on delete cascade, base_version int,
 work_date date not null, proposed_start timestamptz not null, proposed_end timestamptz not null,
 break_minutes int not null check(break_minutes>=0), reason text not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewed_by uuid references auth.users, reviewed_at timestamptz, review_note text not null default '',
 created_at timestamptz not null default now(), created_by uuid not null references auth.users,
 check(proposed_end>proposed_start), check(proposed_end<=proposed_start+interval '48 hours')
);
create unique index if not exists spa_attendance_one_request on public.spa_attendance_requests(attendance_id) where status='pending' and attendance_id is not null;

create or replace function spa_private.attendance_staff() returns uuid language plpgsql stable security definer set search_path='' as $$
declare person uuid;
begin
 if spa_private.role_name() is null then raise exception 'FORBIDDEN'; end if;
 select r.staff_id into person from public.spa_roles r join public.spa_staff s on s.id=r.staff_id
 where r.user_id=auth.uid() and r.active and s.active and s.employment_status='active' and s.archived_at is null;
 if person is null then raise exception 'STAFF_NOT_ACTIVE'; end if;
 return person;
end $$;
create or replace function spa_private.attendance_owner() returns void language plpgsql stable security definer set search_path='' as $$
begin if spa_private.role_name() is distinct from 'owner' then raise exception 'FORBIDDEN'; end if; end $$;
create or replace function spa_private.attendance_distance(a double precision,b double precision,c double precision,d double precision)
returns double precision language sql immutable set search_path='' as $$
 select 6371000*2*asin(sqrt(least(1.0,power(sin(radians(c-a)/2),2)+cos(radians(a))*cos(radians(c))*power(sin(radians(d-b)/2),2))))
$$;

create or replace function public.spa_attendance_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); today date:=(now() at time zone 'Asia/Taipei')::date;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return jsonb_build_object('server_time',now(),'settings',(select to_jsonb(s)-'updated_by' from public.spa_attendance_settings s),
 'open',(select to_jsonb(a) from public.spa_attendance a where a.staff_id=person and a.status='open'),
 'today_roster',(select to_jsonb(s) from spa_private.staff_shift_window(person,today) s),
 'rows',coalesce((select jsonb_agg(to_jsonb(a) order by work_date desc,created_at desc) from public.spa_attendance a where a.staff_id=person and a.work_date between p_from and p_to),'[]'),
 'events',coalesce((select jsonb_agg(to_jsonb(e) order by recorded_at) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where a.staff_id=person and (a.work_date between p_from and p_to or a.status='open')),'[]'),
 'requests',coalesce((select jsonb_agg(to_jsonb(r) order by created_at desc) from public.spa_attendance_requests r where r.staff_id=person and r.work_date between p_from and p_to),'[]'));
end $$;

create or replace function public.spa_attendance_punch(p_request uuid,p_kind text,p_latitude double precision,p_longitude double precision,p_accuracy double precision,p_reason text default '',p_location_error text default '',p_break_minutes int default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); cfg public.spa_attendance_settings; a public.spa_attendance; prior public.spa_attendance_events;
 v_flags text[]:='{}'; dist double precision; today date:=(now() at time zone 'Asia/Taipei')::date; business_day date; roster record; previous_roster record;
 shift_start timestamptz; shift_end timestamptz; reason text:=btrim(coalesce(p_reason,''));
begin
 if p_request is null or p_kind is null or p_kind not in ('in','out') or length(reason)>1000 or p_break_minutes is null or p_break_minutes<0 or length(coalesce(p_location_error,''))>80 then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726099); perform pg_advisory_xact_lock(hashtextextended(person::text,726031));
 select * into prior from public.spa_attendance_events where request_id=p_request;
 if found then
  if prior.staff_id<>person or prior.kind<>p_kind then raise exception 'REQUEST_CONFLICT'; end if;
  return (select to_jsonb(t)||jsonb_build_object('replayed',true) from public.spa_attendance t where t.id=prior.attendance_id);
 end if;
 select * into cfg from public.spa_attendance_settings;
 if p_latitude is null or p_longitude is null or p_accuracy is null then
  if p_latitude is not null or p_longitude is not null or p_accuracy is not null or length(coalesce(p_location_error,''))=0 then raise exception 'INVALID_LOCATION'; end if;
  v_flags:=array_append(v_flags,'location_unavailable');
 else
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 or p_accuracy<=0 or p_accuracy>100000 or p_latitude::text in ('NaN','Infinity','-Infinity') or p_longitude::text in ('NaN','Infinity','-Infinity') or p_accuracy::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_LOCATION'; end if;
  dist:=spa_private.attendance_distance(cfg.latitude,cfg.longitude,p_latitude,p_longitude);
  if p_accuracy>cfg.max_accuracy_m then v_flags:=array_append(v_flags,'low_accuracy'); end if;
  if dist>cfg.radius_m then v_flags:=array_append(v_flags,'outside_store');
  elsif dist+p_accuracy>cfg.radius_m then v_flags:=array_append(v_flags,'boundary_uncertain'); end if;
 end if;
 select * into a from public.spa_attendance where staff_id=person and status='open' for update;
 if p_kind='in' then
  if a.id is not null then raise exception 'ATTENDANCE_ALREADY_IN'; end if;
  business_day:=today; select * into roster from spa_private.staff_shift_window(person,today);
  select * into previous_roster from spa_private.staff_shift_window(person,today-1);
  if previous_roster.is_working and previous_roster.end_minute>1440
   and now()<(((today-1)::timestamp+make_interval(mins=>previous_roster.end_minute)) at time zone 'Asia/Taipei')
   and (not roster.is_working or now()<((today::timestamp+make_interval(mins=>roster.start_minute)) at time zone 'Asia/Taipei')) then
   business_day:=today-1; roster:=previous_roster;
  end if;
  if roster.is_working then
   shift_start:=(business_day::timestamp+make_interval(mins=>roster.start_minute)) at time zone 'Asia/Taipei';
   shift_end:=(business_day::timestamp+make_interval(mins=>roster.end_minute)) at time zone 'Asia/Taipei';
   if now()>shift_start+make_interval(mins=>cfg.grace_minutes) then v_flags:=array_append(v_flags,'late'); end if;
   if now()<shift_start-interval '60 minutes' then v_flags:=array_append(v_flags,'early_arrival'); end if;
  else v_flags:=array_append(v_flags,'no_roster'); end if;
  if exists(select 1 from public.spa_time_off where staff_id=person and starts_at<=now() and ends_at>now()) then v_flags:=array_append(v_flags,'time_off'); end if;
  if v_flags&&array['location_unavailable','low_accuracy','outside_store','boundary_uncertain','no_roster','time_off','early_arrival'] and length(reason)=0 then raise exception 'ATTENDANCE_REASON_REQUIRED'; end if;
  insert into public.spa_attendance(staff_id,work_date,clock_in,effective_start,shift_start,shift_end,grace_minutes,flags)
  values(person,business_day,now(),now(),shift_start,shift_end,cfg.grace_minutes,v_flags) returning * into a;
 else
  if a.id is null then raise exception 'ATTENDANCE_NOT_IN'; end if;
  if now()<=a.clock_in or extract(epoch from now()-a.clock_in)/60<=p_break_minutes then raise exception 'ATTENDANCE_TOO_SHORT'; end if;
  if now()>a.clock_in+make_interval(mins=>cfg.max_shift_minutes) then v_flags:=array_append(v_flags,'long_shift'); end if;
  if a.shift_end is not null and now()<a.shift_end-make_interval(mins=>a.grace_minutes) then v_flags:=array_append(v_flags,'early_departure'); end if;
  if v_flags&&array['location_unavailable','low_accuracy','outside_store','boundary_uncertain','long_shift'] and length(reason)=0 then raise exception 'ATTENDANCE_REASON_REQUIRED'; end if;
  update public.spa_attendance set clock_out=now(),effective_end=now(),break_minutes=p_break_minutes,status='pending',
   flags=coalesce((select array_agg(distinct f) from unnest(a.flags||v_flags) f),'{}'),version=version+1,updated_at=now() where id=a.id returning * into a;
 end if;
 insert into public.spa_attendance_events(request_id,attendance_id,staff_id,kind,latitude,longitude,accuracy_m,distance_m,flags,reason,location_error,geofence_snapshot,created_by)
 values(p_request,a.id,person,p_kind,p_latitude,p_longitude,p_accuracy,dist,v_flags,reason,coalesce(p_location_error,''),to_jsonb(cfg)-'updated_by',auth.uid());
 perform spa_private.audit('attendance.punched',a.id::text,jsonb_build_object('kind',p_kind,'flags',v_flags));
 return to_jsonb(a);
end $$;

create or replace function public.spa_attendance_request(p_request uuid,p_attendance uuid,p_date date,p_start timestamptz,p_end timestamptz,p_break_minutes int,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); result public.spa_attendance_requests; a public.spa_attendance;
begin
 perform pg_advisory_xact_lock(726099);
 if p_request is null or p_date is null or p_start is null or p_end is null or p_end<=p_start or p_end>p_start+interval '48 hours' or p_end>now()
  or (p_start at time zone 'Asia/Taipei')::date not between p_date and p_date+1 or p_break_minutes is null or p_break_minutes<0
  or extract(epoch from p_end-p_start)/60<=p_break_minutes or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'INVALID_INPUT'; end if;
 select * into result from public.spa_attendance_requests where request_id=p_request;
 if found then if result.staff_id<>person then raise exception 'REQUEST_CONFLICT'; end if; return result.id; end if;
 if p_attendance is not null then
  select * into a from public.spa_attendance where id=p_attendance and staff_id=person for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  if a.work_date<>p_date then raise exception 'INVALID_DATE'; end if;
  if exists(select 1 from public.spa_attendance_requests where attendance_id=a.id and status='pending') then raise exception 'ATTENDANCE_REQUEST_PENDING'; end if;
 end if;
 insert into public.spa_attendance_requests(request_id,staff_id,attendance_id,base_version,work_date,proposed_start,proposed_end,break_minutes,reason,created_by)
 values(p_request,person,a.id,a.version,p_date,p_start,p_end,p_break_minutes,btrim(p_reason),auth.uid()) returning * into result;
 perform spa_private.audit('attendance.requested',result.id::text,jsonb_build_object('attendance',a.id,'reason',p_reason));
 return result.id;
end $$;

-- Protect all manual and punch-linked approved work entries from duplicate wages
-- and changes to finalized periods. The same lock serializes payroll finalization.
create or replace function spa_private.attendance_time_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(726099);
 if tg_op<>'INSERT' and exists(select 1 from public.spa_payroll_runs r where r.status='finalized' and old.work_date between r.period_start and r.period_end) then raise exception 'PAYROLL_LOCKED'; end if;
 if tg_op='DELETE' then
  update public.spa_attendance set status='pending',review_note='薪資工時已重設，請重新審核出勤。',version=version+1,updated_at=now() where time_entry_id=old.id;
  return old;
 end if;
 if exists(select 1 from public.spa_payroll_runs r where r.status='finalized' and new.work_date between r.period_start and r.period_end) then raise exception 'PAYROLL_LOCKED'; end if;
 if new.status='approved' and exists(select 1 from public.spa_time_entries t where t.staff_id=new.staff_id and t.id<>new.id and t.status='approved' and t.started_at<new.ended_at and t.ended_at>new.started_at) then raise exception 'ATTENDANCE_OVERLAP'; end if;
 return new;
end $$;
drop trigger if exists spa_attendance_time_guard on public.spa_time_entries;
create trigger spa_attendance_time_guard before insert or update or delete on public.spa_time_entries for each row execute function spa_private.attendance_time_guard();
create or replace function spa_private.attendance_payroll_lock() returns trigger language plpgsql security definer set search_path='' as $$
begin perform pg_advisory_xact_lock(726099); return new; end $$;
drop trigger if exists spa_attendance_payroll_lock on public.spa_payroll_runs;
create trigger spa_attendance_payroll_lock before insert or update on public.spa_payroll_runs for each row execute function spa_private.attendance_payroll_lock();

create or replace function public.spa_attendance_review(p_attendance uuid,p_version int,p_approve boolean,p_start timestamptz,p_end timestamptz,p_break_minutes int,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare a public.spa_attendance; entry uuid; duration int; old jsonb;
begin
 perform spa_private.attendance_owner(); perform pg_advisory_xact_lock(726099);
 select * into a from public.spa_attendance where id=p_attendance for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_version is distinct from a.version then raise exception 'ATTENDANCE_STALE'; end if;
 if p_approve is null or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 if exists(select 1 from public.spa_payroll_runs r where r.status='finalized' and a.work_date between r.period_start and r.period_end) then raise exception 'PAYROLL_LOCKED'; end if;
 old:=to_jsonb(a); entry:=a.time_entry_id;
 if p_approve then
  if p_start is null or p_end is null or p_end<=p_start or p_end>now() or p_end>p_start+interval '48 hours' or p_break_minutes is null or p_break_minutes<0
   or (p_start at time zone 'Asia/Taipei')::date not between a.work_date and a.work_date+1 then raise exception 'INVALID_INPUT'; end if;
  duration:=floor(extract(epoch from p_end-p_start)/60)::int;
  if duration<=p_break_minutes then raise exception 'INVALID_INPUT'; end if;
  if entry is null then
   insert into public.spa_time_entries(staff_id,work_date,started_at,ended_at,break_minutes,status,note,created_by)
   values(a.staff_id,a.work_date,p_start,p_start+make_interval(mins=>duration),p_break_minutes,'approved','出勤審核：'||btrim(p_reason),auth.uid()) returning id into entry;
  else update public.spa_time_entries set started_at=p_start,ended_at=p_start+make_interval(mins=>duration),break_minutes=p_break_minutes,status='approved',note='出勤審核：'||btrim(p_reason) where id=entry; end if;
 else
  if entry is not null then update public.spa_time_entries set status='rejected',note='出勤撤回：'||btrim(p_reason) where id=entry; end if;
 end if;
 update public.spa_attendance set status=case when p_approve then 'approved' else 'rejected' end,effective_start=case when p_approve then p_start else effective_start end,
 effective_end=case when p_approve then p_end else effective_end end,break_minutes=case when p_approve then p_break_minutes else break_minutes end,
 time_entry_id=entry,review_note=btrim(p_reason),reviewed_by=auth.uid(),reviewed_at=now(),version=version+1,updated_at=now() where id=a.id;
 perform spa_private.audit('attendance.reviewed',a.id::text,jsonb_build_object('old',old,'new',(select to_jsonb(t) from public.spa_attendance t where t.id=a.id),'reason',p_reason));
 return a.id;
end $$;

create or replace function public.spa_attendance_request_review(p_request uuid,p_approve boolean,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.spa_attendance_requests; a public.spa_attendance; target uuid; roster record;
begin
 perform spa_private.attendance_owner(); perform pg_advisory_xact_lock(726099);
 select * into r from public.spa_attendance_requests where id=p_request for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if r.status<>'pending' then raise exception 'ATTENDANCE_STALE'; end if;
 if p_approve is null or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 target:=r.attendance_id;
 if p_approve then
  if target is null then
   select * into roster from spa_private.staff_shift_window(r.staff_id,r.work_date);
   insert into public.spa_attendance(staff_id,work_date,effective_start,effective_end,break_minutes,status,flags,shift_start,shift_end)
   values(r.staff_id,r.work_date,r.proposed_start,r.proposed_end,r.break_minutes,'pending',array['manual_request'],
    case when roster.is_working then (r.work_date::timestamp+make_interval(mins=>roster.start_minute)) at time zone 'Asia/Taipei' end,
    case when roster.is_working then (r.work_date::timestamp+make_interval(mins=>roster.end_minute)) at time zone 'Asia/Taipei' end) returning * into a;
   target:=a.id;
  else
   select * into a from public.spa_attendance where id=target for update;
   if a.version is distinct from r.base_version then raise exception 'ATTENDANCE_STALE'; end if;
  end if;
  perform public.spa_attendance_review(target,a.version,true,r.proposed_start,r.proposed_end,r.break_minutes,p_reason);
 end if;
 update public.spa_attendance_requests set status=case when p_approve then 'approved' else 'rejected' end,attendance_id=target,reviewed_by=auth.uid(),reviewed_at=now(),review_note=btrim(p_reason) where id=r.id;
 perform spa_private.audit('attendance.request_reviewed',r.id::text,jsonb_build_object('approved',p_approve,'reason',p_reason));
 return r.id;
end $$;

create or replace function public.spa_attendance_admin(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.attendance_owner();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return jsonb_build_object('server_time',now(),'settings',(select to_jsonb(s)-'updated_by' from public.spa_attendance_settings s),
 'rows',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('employee',s.name) order by a.work_date desc,a.created_at desc) from public.spa_attendance a join public.spa_staff s on s.id=a.staff_id where a.work_date between p_from and p_to or a.status='open'),'[]'),
 'events',coalesce((select jsonb_agg(to_jsonb(e) order by recorded_at) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where a.work_date between p_from and p_to or a.status='open'),'[]'),
 'requests',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('employee',s.name) order by r.created_at desc) from public.spa_attendance_requests r join public.spa_staff s on s.id=r.staff_id where r.work_date between p_from and p_to),'[]'));
end $$;
create or replace function public.spa_attendance_setting_save(p_latitude double precision,p_longitude double precision,p_radius int,p_accuracy int,p_grace int,p_max_shift int,p_address text)
returns void language plpgsql security definer set search_path='' as $$
declare old jsonb;
begin
 perform spa_private.attendance_owner();
 if p_latitude is null or p_longitude is null or p_radius is null or p_accuracy is null or p_grace is null or p_max_shift is null
  or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 or p_latitude::text='NaN' or p_longitude::text='NaN'
  or p_radius not between 20 and 2000 or p_accuracy not between 5 and 500 or p_grace not between 0 and 60 or p_max_shift not between 60 and 2880 or length(btrim(coalesce(p_address,''))) not between 1 and 200 then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(s) into old from public.spa_attendance_settings s;
 update public.spa_attendance_settings set latitude=p_latitude,longitude=p_longitude,radius_m=p_radius,max_accuracy_m=p_accuracy,grace_minutes=p_grace,max_shift_minutes=p_max_shift,address=btrim(p_address),updated_at=now(),updated_by=auth.uid();
 perform spa_private.audit('attendance.settings', 'store',jsonb_build_object('old',old,'new',(select to_jsonb(s) from public.spa_attendance_settings s)));
end $$;

-- Direct edits of linked entries must go through the attendance review trail.
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
 perform spa_private.audit('time_entry.saved',result::text,jsonb_build_object('old',old,'staff_id',p_staff,'work_date',p_work_date,'started_at',p_started_at,'ended_at',p_ended_at,'break_minutes',p_break_minutes)); return result;
end $$;

alter table public.spa_attendance_settings enable row level security;
alter table public.spa_attendance enable row level security;
alter table public.spa_attendance_events enable row level security;
alter table public.spa_attendance_requests enable row level security;
revoke all on public.spa_attendance_settings,public.spa_attendance,public.spa_attendance_events,public.spa_attendance_requests from public,anon,authenticated;
grant all on public.spa_attendance_settings,public.spa_attendance,public.spa_attendance_events,public.spa_attendance_requests to service_role;
revoke all on function spa_private.attendance_staff(),spa_private.attendance_owner(),spa_private.attendance_distance(double precision,double precision,double precision,double precision),spa_private.attendance_time_guard(),spa_private.attendance_payroll_lock() from public,anon,authenticated;
revoke all on function public.spa_attendance_self(date,date),public.spa_attendance_punch(uuid,text,double precision,double precision,double precision,text,text,int),public.spa_attendance_request(uuid,uuid,date,timestamptz,timestamptz,int,text),public.spa_attendance_review(uuid,int,boolean,timestamptz,timestamptz,int,text),public.spa_attendance_request_review(uuid,boolean,text),public.spa_attendance_admin(date,date),public.spa_attendance_setting_save(double precision,double precision,int,int,int,int,text) from public,anon,authenticated;
grant execute on function public.spa_attendance_self(date,date),public.spa_attendance_punch(uuid,text,double precision,double precision,double precision,text,text,int),public.spa_attendance_request(uuid,uuid,date,timestamptz,timestamptz,int,text),public.spa_attendance_review(uuid,int,boolean,timestamptz,timestamptz,int,text),public.spa_attendance_request_review(uuid,boolean,text),public.spa_attendance_admin(date,date),public.spa_attendance_setting_save(double precision,double precision,int,int,int,int,text) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
