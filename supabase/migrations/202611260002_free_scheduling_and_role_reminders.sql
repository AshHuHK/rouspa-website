begin;

create table public.spa_schedule_role_reminders (
 role_code text primary key check(role_code in ('full_time','part_time_monthly','part_time_hourly','contractor')),
 name text not null,
 reminder_text text not null default '' check(length(reminder_text)<=4000),
 display_order int not null,
 version int not null default 1,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users
);
alter table public.spa_schedule_role_reminders enable row level security;
revoke all on public.spa_schedule_role_reminders from public,anon,authenticated;
insert into public.spa_schedule_role_reminders(role_code,name,reminder_text,display_order) values
 ('full_time','正職人員','每月原則上安排22天班，週五、六、日為固定出勤日，原則上不安排休假。若長期無法配合約定班別，將協商重新調整人員配置。',10),
 ('contractor','承攬人員','每月原則上需開放至少20天預約，每日開放預約時數不得少於4小時。若長期無法配合原約定之服務時段，將重新協商合作方式及人員配置。',20),
 ('part_time_hourly','兼職時薪人員','原則上固定於週五、六、日上班，平日可依個人時間彈性安排。每月因私人行程申請事假原則上不超過3次。若長期無法配合約定班別，將協商重新調整人員配置。',30),
 ('part_time_monthly','兼職月薪人員','每週原則上安排週五、六、日及任選兩天平日上班，週五、六、日為固定出勤日，原則上不安排休假。若長期無法配合約定班別，將協商重新調整人員配置。',40);

create function spa_private.staff_schedule_role(p_staff uuid) returns text
language sql stable security definer set search_path='' as $$
 select case when j.work_category='owner' then null
  when j.work_category='technician' and a.category='01' then 'full_time'
  when j.work_category='technician' and a.category='02' then 'part_time_monthly'
  when j.work_category='technician' and a.category='03' then 'part_time_hourly'
  when j.work_category='technician' and a.category='04' then 'contractor'
  when s.employment_type_code='contractor' then 'contractor'
  when s.employment_type_code='full_time' then 'full_time'
  when s.employment_type_code='part_time' then case when c.pay_basis='monthly' then 'part_time_monthly' else 'part_time_hourly' end
 end
 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
 left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code
 left join spa_private.payroll_notice_staff a on a.staff_id=s.id and a.rule_id=spa_private.payroll_notice_rule_on((now() at time zone 'Asia/Taipei')::date)
 where s.id=p_staff
$$;
revoke all on function spa_private.staff_schedule_role(uuid) from public,anon,authenticated;

create function public.spa_schedule_reminder_save(p_role text,p_text text,p_version int) returns void
language plpgsql security definer set search_path='' as $$
declare old public.spa_schedule_role_reminders;
begin
 perform spa_private.require_role(array['owner']);
 if p_text is null or length(p_text)>4000 then raise exception 'INVALID_INPUT'; end if;
 select * into old from public.spa_schedule_role_reminders where role_code=p_role for update;
 if not found then raise exception 'INVALID_INPUT'; end if;
 if p_version is distinct from old.version then raise exception 'SCHEDULE_REMINDER_STALE'; end if;
 update public.spa_schedule_role_reminders set reminder_text=btrim(p_text),version=version+1,updated_at=now(),updated_by=auth.uid() where role_code=p_role;
 perform spa_private.audit('schedule.reminder_saved',p_role,jsonb_build_object('old_text',old.reminder_text,'new_text',btrim(p_text)));
end $$;
revoke all on function public.spa_schedule_reminder_save(text,text,int) from public,anon,authenticated;
grant execute on function public.spa_schedule_reminder_save(text,text,int) to authenticated,service_role;
create trigger spa_live_invalidation after insert or update or delete or truncate on public.spa_schedule_role_reminders
 for each statement execute function spa_private.queue_live_invalidation('team,schedule,settings','');

alter function public.spa_staff_schedule_plan() rename to spa_staff_schedule_plan_without_reminder;
alter function public.spa_staff_schedule_plan_without_reminder() set schema spa_private;
revoke all on function spa_private.spa_staff_schedule_plan_without_reminder() from public,anon,authenticated;
create function public.spa_staff_schedule_plan() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.spa_staff_schedule_plan_without_reminder();
 role text:=spa_private.staff_schedule_role(spa_private.current_staff_id());
begin
 return (result-'max_off_per_day')||jsonb_build_object('scheduling_mode','free',
  'schedule_reminder',(select jsonb_build_object('role_code',r.role_code,'name',r.name,'text',r.reminder_text,'version',r.version)
   from public.spa_schedule_role_reminders r where r.role_code=role));
end $$;
revoke all on function public.spa_staff_schedule_plan() from public,anon,authenticated;
grant execute on function public.spa_staff_schedule_plan() to authenticated,service_role;

alter function public.spa_team_os() rename to spa_team_os_without_schedule_reminders;
alter function public.spa_team_os_without_schedule_reminders() set schema spa_private;
revoke all on function spa_private.spa_team_os_without_schedule_reminders() from public,anon,authenticated;
create function public.spa_team_os() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:=spa_private.spa_team_os_without_schedule_reminders();
begin
 return result||jsonb_build_object(
  'schedule_reminders',(select jsonb_agg(to_jsonb(r)-'updated_by' order by r.display_order) from public.spa_schedule_role_reminders r),
  'staff',(select jsonb_agg(s.value||jsonb_build_object('schedule_role_code',spa_private.staff_schedule_role((s.value->>'id')::uuid)) order by s.ordinality)
   from jsonb_array_elements(result->'staff') with ordinality s));
end $$;
revoke all on function public.spa_team_os() from public,anon,authenticated;
grant execute on function public.spa_team_os() to authenticated,service_role;

create or replace function public.spa_staff_schedule_submit(p_month date,p_days jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare person uuid:=spa_private.current_staff_id(); today date:=(now() at time zone 'Asia/Taipei')::date; target date:=(date_trunc('month',(now() at time zone 'Asia/Taipei')::date)+interval '1 month')::date; final_date date; expected int; item jsonb; work_date date; working boolean; start_min int; end_min int;
begin
 perform spa_private.require_team(); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726101);
 if person is null then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if extract(day from today)::int not between 1 and 7 then raise exception 'SCHEDULE_LOCKED'; end if;
 if p_month is null or date_trunc('month',p_month)::date<>target or p_days is null or jsonb_typeof(p_days)<>'array' then raise exception 'INVALID_SCHEDULE'; end if;
 final_date:=(target+interval '1 month - 1 day')::date; expected:=final_date-target+1;
 if jsonb_array_length(p_days)<>expected or (select count(distinct x->>'date') from jsonb_array_elements(p_days) x)<>expected
  or exists(select 1 from jsonb_array_elements(p_days) x where x->>'date' is null or (x->>'date')::date not between target and final_date) then raise exception 'INVALID_SCHEDULE'; end if;
 for item in select * from jsonb_array_elements(p_days) loop
  work_date:=(item->>'date')::date; working:=(item->>'is_working')::boolean; start_min:=(item->>'start_minute')::int; end_min:=(item->>'end_minute')::int;
  if working is null or start_min is null or end_min is null or start_min<0 or end_min<=start_min or end_min>2880 then raise exception 'INVALID_SCHEDULE'; end if;
  insert into public.spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by,updated_at)
  values(person,work_date,working,start_min,end_min,'員工月班表',auth.uid(),now())
  on conflict(staff_id,business_date) do update set is_working=excluded.is_working,start_minute=excluded.start_minute,end_minute=excluded.end_minute,note=excluded.note,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 end loop;
 insert into public.spa_staff_schedule_submissions(staff_id,schedule_month,submitted_by)
 values(person,target,auth.uid()) on conflict(staff_id,schedule_month) do update set version=spa_staff_schedule_submissions.version+1,submitted_at=now(),submitted_by=auth.uid();
 perform spa_private.audit('schedule.employee_submitted',person::text,jsonb_build_object('month',target,'days',expected));
 return (select to_jsonb(s) from public.spa_staff_schedule_submissions s where s.staff_id=person and s.schedule_month=target);
end $$;

notify pgrst,'reload schema';
commit;
