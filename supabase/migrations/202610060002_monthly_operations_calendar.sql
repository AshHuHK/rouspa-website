begin;

-- A single bounded monthly read model for the dashboard.  It keeps the
-- calendar consistent with the same store hours, dated roster overrides,
-- weekly shifts, leave, actual appointment staff and beds used elsewhere.
create or replace function public.spa_monthly_operations(p_month date)
returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 month_start date:=date_trunc('month',p_month)::date;
 month_end date;
 work_date date;
 day_start timestamptz;
 day_end timestamptz;
 hours jsonb;
 shifts jsonb;
 rests jsonb;
 leaves jsonb;
 appointments jsonb;
 days jsonb:='[]'::jsonb;
begin
 perform spa_private.require_permission('dashboard.view');
 if p_month is null then raise exception 'INVALID_DATE'; end if;
 month_end:=(month_start+interval '1 month - 1 day')::date;

 for work_date in select generate_series(month_start,month_end,interval '1 day')::date loop
  day_start:=work_date::timestamp at time zone 'Asia/Taipei';
  day_end:=(work_date+1)::timestamp at time zone 'Asia/Taipei';
  select to_jsonb(w) into hours from spa_private.business_window(work_date) w;

  select coalesce(jsonb_agg(jsonb_build_object(
   'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),
   'start_minute',roster.start_minute,'end_minute',roster.end_minute,
   'source',roster.source,'note',roster.note
  ) order by roster.start_minute,s.display_order,s.name),'[]'::jsonb) into shifts
  from public.spa_staff s
  left join public.spa_job_titles j on j.id=s.job_title_id
  cross join lateral spa_private.staff_shift_window(s.id,work_date) roster
  where s.active and s.employment_status='active' and s.archived_at is null and roster.is_working;

  select coalesce(jsonb_agg(jsonb_build_object(
   'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),
   'source',roster.source,'note',roster.note
  ) order by s.display_order,s.name),'[]'::jsonb) into rests
  from public.spa_staff s
  left join public.spa_job_titles j on j.id=s.job_title_id
  cross join lateral spa_private.staff_shift_window(s.id,work_date) roster
  where s.active and s.employment_status='active' and s.archived_at is null and not roster.is_working;

  select coalesce(jsonb_agg(jsonb_build_object(
   'id',o.id,'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),
   'starts_at',o.starts_at,'ends_at',o.ends_at,'reason',o.reason
  ) order by o.starts_at,s.display_order,s.name),'[]'::jsonb) into leaves
  from public.spa_time_off o
  join public.spa_staff s on s.id=o.staff_id
  left join public.spa_job_titles j on j.id=s.job_title_id
  where s.active and s.employment_status='active' and s.archived_at is null
   and o.starts_at<day_end and o.ends_at>day_start;

  select coalesce(jsonb_agg(jsonb_build_object(
   'id',a.id,'reference',a.reference,'starts_at',a.starts_at,'ends_at',a.ends_at,
   'blocked_until',a.blocked_until,'status',a.status,'customer_name',c.name,
   'service_name',coalesce(a.service_name_snapshot,a.service_name),
   'staff_id',s.id,'staff_name',s.name,'staff_title',coalesce(j.name,s.title),
   'room_id',r.id,'room_name',r.name
  ) order by a.starts_at,r.name),'[]'::jsonb) into appointments
  from public.spa_appointments a
  join public.spa_customers c on c.id=a.customer_id
  join public.spa_staff s on s.id=a.staff_id
  left join public.spa_job_titles j on j.id=s.job_title_id
  join public.spa_rooms r on r.id=a.room_id
  where a.business_date=work_date and a.status not in ('cancelled','no_show');

  days:=days||jsonb_build_array(jsonb_build_object(
   'date',work_date,'store_hours',coalesce(hours,'{}'::jsonb),
   'shift_count',jsonb_array_length(shifts),'off_count',(
    select count(distinct staff_id) from (
     select (x->>'staff_id')::uuid staff_id from jsonb_array_elements(rests) x
     union all select (x->>'staff_id')::uuid from jsonb_array_elements(leaves) x
    ) off_people
   ),
   'appointment_count',jsonb_array_length(appointments),
   'room_count',(select count(distinct x->>'room_id') from jsonb_array_elements(appointments) x),
   'shifts',shifts,'rests',rests,'leaves',leaves,'appointments',appointments
  ));
 end loop;

 return jsonb_build_object(
  'month',to_char(month_start,'YYYY-MM'),'from',month_start,'to',month_end,
  'active_staff_count',(select count(*) from public.spa_staff where active and employment_status='active' and archived_at is null),
  'active_room_count',(select count(*) from public.spa_rooms where active),
  'days',days
 );
end $$;

revoke all on function public.spa_monthly_operations(date) from public,anon,authenticated;
grant execute on function public.spa_monthly_operations(date) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
