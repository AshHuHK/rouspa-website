-- Every new clock-in and clock-out must carry a fresh browser location.
-- Legacy events stay intact; missing punches use the audited correction workflow.
-- A trigger guards every writer and rolls back the entire punch if evidence is absent.
begin;
create or replace function spa_private.attendance_location_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.latitude is null or new.longitude is null or new.accuracy_m is null
  or new.latitude not between -90 and 90 or new.longitude not between -180 and 180
  or new.accuracy_m<=0 or new.accuracy_m>100000
  or new.latitude::text in ('NaN','Infinity','-Infinity')
  or new.longitude::text in ('NaN','Infinity','-Infinity')
  or new.accuracy_m::text in ('NaN','Infinity','-Infinity')
  or coalesce(new.location_error,'')<>'' then
  raise exception 'INVALID_LOCATION';
 end if;
 return new;
end $$;
revoke all on function spa_private.attendance_location_guard() from public,anon,authenticated;
drop trigger if exists spa_attendance_location_guard on public.spa_attendance_events;
create trigger spa_attendance_location_guard before insert on public.spa_attendance_events
for each row execute function spa_private.attendance_location_guard();
commit;
