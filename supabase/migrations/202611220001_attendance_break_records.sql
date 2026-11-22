begin;

create table public.spa_attendance_breaks (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null unique,
 attendance_id uuid not null references public.spa_attendance on delete cascade,
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 created_at timestamptz not null default now(),
 created_by uuid not null references auth.users,
 check (ends_at>starts_at)
);
create index spa_attendance_breaks_attendance on public.spa_attendance_breaks(attendance_id,starts_at);
alter table public.spa_attendance_breaks enable row level security;
revoke all on public.spa_attendance_breaks from public,anon,authenticated;

alter table public.spa_attendance_requests
 alter column proposed_start drop not null,
 alter column proposed_end drop not null,
 add column reason_only boolean not null default false,
 add constraint spa_attendance_request_times check (
  (proposed_start is not null and proposed_end is not null) or
  (reason_only and status<>'approved' and proposed_start is null and proposed_end is null)
 );

create function spa_private.attendance_break_total(p_attendance uuid) returns int
language sql stable set search_path='' as $$
 select sum(extract(epoch from b.ends_at-b.starts_at)/60)::int
 from public.spa_attendance_breaks b where b.attendance_id=p_attendance
$$;

create function public.spa_attendance_break_add(p_request uuid,p_attendance uuid,p_start timestamptz,p_end timestamptz) returns uuid
language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); a public.spa_attendance; prior public.spa_attendance_breaks; result uuid;
begin
 perform pg_advisory_xact_lock(726099);
 if p_request is null or p_attendance is null or p_start is null or p_end is null or not isfinite(p_start) or not isfinite(p_end)
  or p_end<=p_start or p_end>now() or date_trunc('minute',p_start)<>p_start or date_trunc('minute',p_end)<>p_end then
  raise exception 'ATTENDANCE_BREAK_TIME';
 end if;
 select * into a from public.spa_attendance where id=p_attendance and staff_id=person for update;
 if not found then raise exception 'FORBIDDEN'; end if;
 select * into prior from public.spa_attendance_breaks where request_id=p_request;
 if found then
  if prior.attendance_id<>a.id or prior.starts_at<>p_start or prior.ends_at<>p_end then raise exception 'REQUEST_CONFLICT'; end if;
  return prior.id;
 end if;
 if a.status<>'open' then raise exception 'ATTENDANCE_NOT_IN'; end if;
 if p_start<date_trunc('minute',a.clock_in) then raise exception 'ATTENDANCE_BREAK_TIME'; end if;
 if exists(select 1 from public.spa_attendance_breaks b where b.attendance_id=a.id and b.starts_at<p_end and b.ends_at>p_start) then
  raise exception 'ATTENDANCE_BREAK_OVERLAP';
 end if;
 insert into public.spa_attendance_breaks(request_id,attendance_id,starts_at,ends_at,created_by)
 values(p_request,a.id,p_start,p_end,auth.uid()) returning id into result;
 update public.spa_attendance set break_minutes=spa_private.attendance_break_total(a.id),version=version+1,updated_at=now() where id=a.id;
 perform spa_private.audit('attendance.break_recorded',result::text,jsonb_build_object('attendance',a.id));
 return result;
end $$;

create function public.spa_attendance_punch_v2(p_request uuid,p_kind text,p_latitude double precision,p_longitude double precision,p_accuracy double precision)
returns jsonb language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); rests int:=0;
begin
 perform pg_advisory_xact_lock(726099);
 if p_kind='out' then
  select a.break_minutes into rests from public.spa_attendance a where a.staff_id=person and a.status='open';
 end if;
 begin
  return public.spa_attendance_punch(p_request,p_kind,p_latitude,p_longitude,p_accuracy,'','',coalesce(rests,0));
 exception when raise_exception then
  if sqlerrm<>'ATTENDANCE_REASON_REQUIRED' then raise; end if;
 end;
 return public.spa_attendance_punch(p_request,p_kind,p_latitude,p_longitude,p_accuracy,
  '系統依定位或班表標記，待店主審核','',coalesce(rests,0));
end $$;

create function spa_private.attendance_break_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare rests int:=spa_private.attendance_break_total(new.id);
begin
 if rests is null then return new; end if;
 if new.status='pending' and old.status='open' then new.break_minutes:=rests; end if;
 if new.status='approved' and (new.break_minutes<>rests or exists(
  select 1 from public.spa_attendance_breaks b where b.attendance_id=new.id
   and (b.starts_at<date_trunc('minute',new.effective_start) or b.ends_at>new.effective_end)
 )) then raise exception 'ATTENDANCE_BREAK_REVIEW'; end if;
 return new;
end $$;
create trigger spa_attendance_break_guard before update of status,effective_start,effective_end,break_minutes on public.spa_attendance
 for each row execute function spa_private.attendance_break_guard();

create function public.spa_attendance_request_quick(p_request uuid,p_attendance uuid,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); a public.spa_attendance; r public.spa_attendance_requests; reason text:=btrim(coalesce(p_reason,''));
begin
 perform pg_advisory_xact_lock(726099);
 if p_request is null or length(reason) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 select * into r from public.spa_attendance_requests where request_id=p_request;
 if found then
  if r.staff_id<>person or not r.reason_only or r.reason<>reason
   or (case when r.base_version is null then null else r.attendance_id end) is distinct from p_attendance then raise exception 'REQUEST_CONFLICT'; end if;
  return r.id;
 end if;
 if p_attendance is not null then
  select * into a from public.spa_attendance where id=p_attendance and staff_id=person for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  if exists(select 1 from public.spa_attendance_requests where attendance_id=a.id and status='pending') then raise exception 'ATTENDANCE_REQUEST_PENDING'; end if;
 elsif exists(select 1 from public.spa_attendance_requests where staff_id=person and reason_only and attendance_id is null and status='pending' and spa_attendance_requests.reason=btrim(p_reason)) then
  raise exception 'ATTENDANCE_REQUEST_PENDING';
 end if;
 insert into public.spa_attendance_requests(request_id,staff_id,attendance_id,base_version,work_date,break_minutes,reason,created_by,reason_only)
 values(p_request,person,a.id,a.version,coalesce(a.work_date,(now() at time zone 'Asia/Taipei')::date),0,reason,auth.uid(),true)
 returning * into r;
 perform spa_private.audit('attendance.requested',r.id::text,jsonb_build_object('attendance',a.id,'reason',reason));
 return r.id;
end $$;

create function public.spa_attendance_request_review_v2(p_request uuid,p_approve boolean,p_reason text,p_date date,p_start timestamptz,p_end timestamptz,p_break_minutes int,p_version int)
returns uuid language plpgsql security definer set search_path='' as $$
declare r public.spa_attendance_requests; a public.spa_attendance;
begin
 perform spa_private.attendance_owner(); perform pg_advisory_xact_lock(726099);
 select * into r from public.spa_attendance_requests where id=p_request for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if r.status<>'pending' then raise exception 'ATTENDANCE_STALE'; end if;
 if p_approve and r.reason_only then
  if p_date is null or p_start is null or p_end is null or not isfinite(p_start) or not isfinite(p_end) or p_end<=p_start
   or p_end>now() or p_end>p_start+interval '48 hours' or (p_start at time zone 'Asia/Taipei')::date not between p_date and p_date+1
   or p_break_minutes is null or p_break_minutes<0 or floor(extract(epoch from p_end-p_start)/60)<=p_break_minutes then raise exception 'INVALID_INPUT'; end if;
  if r.attendance_id is not null then
   select * into a from public.spa_attendance where id=r.attendance_id for update;
   if p_date<>a.work_date then raise exception 'INVALID_DATE'; end if;
   if a.version is distinct from p_version then raise exception 'ATTENDANCE_STALE'; end if;
  end if;
  update public.spa_attendance_requests set work_date=p_date,proposed_start=p_start,proposed_end=p_end,break_minutes=p_break_minutes,base_version=a.version where id=r.id;
 end if;
 return public.spa_attendance_request_review(p_request,p_approve,p_reason);
end $$;

revoke all on function spa_private.attendance_break_total(uuid),spa_private.attendance_break_guard() from public,anon,authenticated;
revoke all on function public.spa_attendance_break_add(uuid,uuid,timestamptz,timestamptz),
 public.spa_attendance_punch_v2(uuid,text,double precision,double precision,double precision),public.spa_attendance_request_quick(uuid,uuid,text),
 public.spa_attendance_request_review_v2(uuid,boolean,text,date,timestamptz,timestamptz,int,int) from public,anon,authenticated;
grant execute on function public.spa_attendance_break_add(uuid,uuid,timestamptz,timestamptz),
 public.spa_attendance_punch_v2(uuid,text,double precision,double precision,double precision),public.spa_attendance_request_quick(uuid,uuid,text),
 public.spa_attendance_request_review_v2(uuid,boolean,text,date,timestamptz,timestamptz,int,int) to authenticated;

create or replace function public.spa_attendance_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid:=spa_private.attendance_staff(); today date:=(now() at time zone 'Asia/Taipei')::date;
begin
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return jsonb_build_object('server_time',now(),'settings',(select to_jsonb(s)-'updated_by' from public.spa_attendance_settings s),
 'open',(select to_jsonb(a) from public.spa_attendance a where a.staff_id=person and a.status='open'),
 'today_roster',(select to_jsonb(s) from spa_private.staff_shift_window(person,today) s),
 'rows',coalesce((select jsonb_agg(to_jsonb(a) order by work_date desc,created_at desc) from public.spa_attendance a where a.staff_id=person and a.work_date between p_from and p_to),'[]'),
 'events',coalesce((select jsonb_agg(to_jsonb(e) order by recorded_at) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where a.staff_id=person and (a.work_date between p_from and p_to or a.status='open')),'[]'),
 'breaks',coalesce((select jsonb_agg(to_jsonb(b) order by b.starts_at) from public.spa_attendance_breaks b join public.spa_attendance a on a.id=b.attendance_id where a.staff_id=person and (a.work_date between p_from and p_to or a.status='open')),'[]'),
 'requests',coalesce((select jsonb_agg(to_jsonb(r) order by created_at desc) from public.spa_attendance_requests r where r.staff_id=person and r.work_date between p_from and p_to),'[]'));
end $$;

create or replace function public.spa_attendance_admin(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.attendance_owner();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return jsonb_build_object('server_time',now(),'settings',(select to_jsonb(s)-'updated_by' from public.spa_attendance_settings s),
 'rows',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('employee',s.name) order by a.work_date desc,a.created_at desc) from public.spa_attendance a join public.spa_staff s on s.id=a.staff_id where a.work_date between p_from and p_to or a.status='open'),'[]'),
 'events',coalesce((select jsonb_agg(to_jsonb(e) order by recorded_at) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where a.work_date between p_from and p_to or a.status='open'),'[]'),
 'breaks',coalesce((select jsonb_agg(to_jsonb(b) order by b.starts_at) from public.spa_attendance_breaks b join public.spa_attendance a on a.id=b.attendance_id where a.work_date between p_from and p_to or a.status='open'),'[]'),
 'requests',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('employee',s.name) order by r.created_at desc) from public.spa_attendance_requests r join public.spa_staff s on s.id=r.staff_id where r.work_date between p_from and p_to),'[]'));
end $$;

alter function public.spa_backup_export(text,date,date) rename to spa_backup_export_without_breaks;
alter function public.spa_backup_export_without_breaks(text,date,date) set schema spa_private;
revoke all on function spa_private.spa_backup_export_without_breaks(text,date,date) from public,anon,authenticated;

create function public.spa_backup_export(p_scope text,p_from date default null,p_to date default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare backup jsonb:=spa_private.spa_backup_export_without_breaks(p_scope,p_from,p_to);
begin
 return backup||jsonb_build_object('attendance_breaks',case when p_scope in ('payroll','all') then coalesce((
  select jsonb_agg(to_jsonb(b) order by b.id)
  from public.spa_attendance_breaks b join public.spa_attendance a on a.id=b.attendance_id
  where p_from is null or a.work_date between p_from and p_to
 ),'[]') else '[]'::jsonb end);
end $$;
revoke all on function public.spa_backup_export(text,date,date) from public,anon,authenticated;
grant execute on function public.spa_backup_export(text,date,date) to authenticated,service_role;

commit;
