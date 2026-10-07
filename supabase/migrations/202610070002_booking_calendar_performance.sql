begin;

create or replace function spa_private.available_staff_count(p_service uuid,p_date date,p_start timestamptz,p_staff uuid default null)
returns int language sql stable security definer set search_path='' as $$
 with cfg as (select * from public.spa_settings),
 hours as (select * from spa_private.business_window(p_date)),
 service as (select * from public.spa_services where id=p_service and active and status='active' and online_booking_enabled),
 timing as (select p_start+make_interval(mins=>s.duration_minutes+s.buffer_minutes) blocked from service s),
 room_capacity as (
  select exists(
   select 1 from public.spa_rooms r cross join timing t
   where r.active and not exists(
    select 1 from public.spa_appointments a
    where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.room_id=r.id
     and a.starts_at<t.blocked and a.blocked_until>p_start
   )
  ) available
 )
 select case when coalesce((select available from room_capacity),false) then coalesce((
  select count(distinct st.id)::int from public.spa_staff st
  join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled
  join lateral spa_private.staff_shift_window(st.id,p_date) roster on roster.is_working
  cross join cfg cross join hours h cross join timing t
  where h.is_open and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable
   and (p_staff is null or st.id=p_staff)
   and p_start>=((p_date::timestamp+make_interval(mins=>greatest(h.opening_minute,roster.start_minute))) at time zone cfg.timezone)
   and t.blocked<=((p_date::timestamp+make_interval(mins=>least(h.closing_minute,roster.end_minute))) at time zone cfg.timezone)
   and not exists(select 1 from public.spa_time_off o where o.staff_id=st.id and o.starts_at<t.blocked and o.ends_at>p_start)
   and not exists(select 1 from public.spa_appointments a where a.status in ('pending','confirmed','checked_in','in_service','completed') and a.staff_id=st.id and a.starts_at<t.blocked and a.blocked_until>p_start)
 ),0) else 0 end
$$;

create index if not exists spa_time_off_staff_time on public.spa_time_off(staff_id,starts_at,ends_at);

create or replace function public.spa_public_slots(p_service uuid,p_date date,p_staff uuid default null)
returns table(time_label text,starts_at timestamptz,available_staff_count int,available boolean)
language plpgsql stable security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; minute int; start_at timestamptz;
begin
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 if p_date is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.public_booking_last_date() then return; end if;
 for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
  start_at:=(p_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
  time_label:=case when minute>=1440 then '翌日 ' else '' end||to_char(p_date::timestamp+make_interval(mins=>minute),'HH24:MI'); starts_at:=start_at;
  available_staff_count:=case when start_at>now()+interval '30 minutes' then spa_private.available_staff_count(p_service,p_date,start_at,p_staff) else 0 end;
  available:=available_staff_count>0; return next;
 end loop;
end $$;

create or replace function public.spa_booking_calendar(p_service uuid,p_month date,p_staff uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; month_start date:=date_trunc('month',p_month)::date; month_end date; work_date date; cfg public.spa_settings; hours record; minute int; at_time timestamptz; slot_count int; staff_count int; has_shift boolean; roster_start int; roster_end int; days jsonb:='[]'::jsonb;
begin
 select * into cfg from public.spa_settings; month_end:=(month_start+interval '1 month - 1 day')::date;
 if p_service is null or p_month is null or month_start not in (date_trunc('month',today)::date,(date_trunc('month',today)+interval '1 month')::date) then raise exception 'INVALID_DATE'; end if;
 if not exists(select 1 from public.spa_services where id=p_service and active and status='active' and online_booking_enabled) then raise exception 'INVALID_SERVICE'; end if;
 if p_staff is not null and not exists(select 1 from public.spa_staff st join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled where st.id=p_staff and st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable) then raise exception 'STAFF_NOT_ACTIVE'; end if;
 for work_date in select generate_series(month_start,month_end,interval '1 day')::date loop
  select * into hours from spa_private.business_window(work_date);
  slot_count:=0; staff_count:=0; has_shift:=false; roster_start:=null; roster_end:=null;
  if p_staff is not null then select sw.is_working,sw.start_minute,sw.end_minute into has_shift,roster_start,roster_end from spa_private.staff_shift_window(p_staff,work_date) sw; has_shift:=coalesce(has_shift,false);
  else select exists(select 1 from public.spa_staff st join public.spa_staff_services sk on sk.staff_id=st.id and sk.service_id=p_service and sk.enabled join lateral spa_private.staff_shift_window(st.id,work_date) sw on sw.is_working where st.active and st.employment_status='active' and st.archived_at is null and st.is_bookable) into has_shift; end if;
  if work_date>=today and work_date<=spa_private.public_booking_last_date() and coalesce(hours.is_open,false) and has_shift then
   for minute in select generate_series(hours.opening_minute,hours.closing_minute-1,cfg.slot_minutes) loop
    at_time:=(work_date::timestamp+make_interval(mins=>minute)) at time zone cfg.timezone;
    if at_time>now()+interval '30 minutes' then
     staff_count:=spa_private.available_staff_count(p_service,work_date,at_time,p_staff);
     if staff_count>0 then slot_count:=1; exit; end if;
    end if;
   end loop;
  end if;
  days:=days||jsonb_build_array(jsonb_build_object('date',work_date,'is_open',coalesce(hours.is_open,false),'has_shift',has_shift,'available_slots',slot_count,'available_staff',staff_count,'start_minute',case when p_staff is not null and has_shift then roster_start end,'end_minute',case when p_staff is not null and has_shift then roster_end end,'status',case when work_date<today then 'past' when not coalesce(hours.is_open,false) or not has_shift then 'off' when slot_count=0 then 'full' else 'open' end));
 end loop;
 return jsonb_build_object('month',to_char(month_start,'YYYY-MM'),'from',month_start,'to',month_end,'days',days);
end $$;

notify pgrst,'reload schema';
commit;
