begin;

-- Use the actual service interval. Suggestions are shared by the full calendar
-- and filtered booking views, and never take part in accepting a booking.
create function spa_private.suggested_beds(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare booking record; component bigint; used int[]:='{}'; intervals tstzrange[]:='{}'; bed int; candidate int;
 slot_range tstzrange; result jsonb:='{}';
begin
 for booking in
  with ordered as (
   select a.id,a.business_date,a.starts_at,a.ends_at,
    max(a.ends_at) over(order by a.starts_at,a.ends_at,a.id rows between unbounded preceding and 1 preceding) as prior_end
   from public.spa_appointments a
   where a.business_date between p_from-1 and p_to+1
    and a.status not in ('cancelled','no_show') and a.starts_at<a.ends_at
  ), grouped as (
   select o.*,sum(case when o.starts_at<o.prior_end then 0 else 1 end) over(order by o.starts_at,o.ends_at,o.id) as cluster,
    case when o.ends_at-o.starts_at>=interval '120 minutes' then 1 when o.ends_at-o.starts_at>=interval '90 minutes' then 2 else 3 end as priority
   from ordered o
  )
  select * from grouped order by cluster,priority,starts_at,id
 loop
  if component is distinct from booking.cluster then
   component:=booking.cluster;
   used:='{}';
   intervals:='{}';
  end if;
  bed:=null;
  slot_range:=tstzrange(booking.starts_at,booking.ends_at,'[)');
  foreach candidate in array (case when booking.priority=3 then array[3,4,1,2] else array[1,2,3,4] end) loop
   if not exists(select 1 from unnest(used,intervals) as occupied(number,span) where occupied.number=candidate and occupied.span && slot_range) then
    bed:=candidate;
    used:=array_append(used,bed);
    intervals:=array_append(intervals,slot_range);
    exit;
   end if;
  end loop;
  if booking.business_date between p_from and p_to then
   result:=result||jsonb_build_object(booking.id::text,bed);
  end if;
 end loop;
 return result;
end $$;
revoke all on function spa_private.suggested_beds(date,date) from public,anon,authenticated;

alter function public.spa_admin_bookings(date,date) rename to spa_admin_bookings_without_bed;
alter function public.spa_admin_bookings_without_bed(date,date) set schema spa_private;
alter function public.spa_monthly_operations(date) rename to spa_monthly_operations_without_bed;
alter function public.spa_monthly_operations_without_bed(date) set schema spa_private;
revoke all on function spa_private.spa_admin_bookings_without_bed(date,date),spa_private.spa_monthly_operations_without_bed(date) from public,anon,authenticated;

create function public.spa_admin_bookings(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb:=spa_private.spa_admin_bookings_without_bed(p_from,p_to);
 beds jsonb:=spa_private.suggested_beds(p_from,p_to);
begin
 return coalesce((
  select jsonb_agg(case when beds ? (a.value->>'id') then
   a.value||jsonb_build_object('suggested_bed',beds->(a.value->>'id')) else a.value end order by a.ordinality)
  from jsonb_array_elements(rows) with ordinality a
 ),'[]');
end $$;

create function public.spa_monthly_operations(p_month date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare calendar jsonb:=spa_private.spa_monthly_operations_without_bed(p_month);
 beds jsonb:=spa_private.suggested_beds((calendar->>'from')::date,(calendar->>'to')::date);
begin
 return jsonb_set(calendar,'{days}',(
  select jsonb_agg(jsonb_set(d.value,'{appointments}',coalesce((
   select jsonb_agg(case when beds ? (a.value->>'id') then
    a.value||jsonb_build_object('suggested_bed',beds->(a.value->>'id')) else a.value end order by a.ordinality)
   from jsonb_array_elements(d.value->'appointments') with ordinality a
  ),'[]')) order by d.ordinality)
  from jsonb_array_elements(calendar->'days') with ordinality d
 ));
end $$;
revoke all on function public.spa_admin_bookings(date,date),public.spa_monthly_operations(date) from public,anon,authenticated;
grant execute on function public.spa_admin_bookings(date,date),public.spa_monthly_operations(date) to authenticated,service_role;

create or replace function public.spa_submit_review(p_token uuid,p_rating int,p_comment text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments;
begin
 perform pg_advisory_xact_lock(726001);
 select ap.* into a from public.spa_appointments ap join public.spa_customers c on c.id=ap.customer_id
 where ap.review_token=p_token and ap.status='completed' and c.status='active' and c.archived_at is null for update of ap,c;
 if not found then raise exception 'REVIEW_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>1000 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_reviews(appointment_id,rating,comment) values(a.id,p_rating,btrim(p_comment)) on conflict(appointment_id) do nothing;
end $$;

commit;
