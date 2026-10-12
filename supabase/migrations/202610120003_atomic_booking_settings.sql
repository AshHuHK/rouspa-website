begin;

-- One visible settings form is one transaction. Previously three parallel
-- requests could update some settings while another field failed validation.
create or replace function public.spa_booking_policy_save(p_open int,p_close int,p_days int,p_auto boolean,p_cancel int,p_max_off int,p_capacity int)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 if p_open is null or p_close is null or p_days is null or p_auto is null or p_cancel is null or p_max_off is null or p_capacity is null
  or p_open not between 0 and 1439 or p_close<=p_open or p_close>2880
  or p_days not between 1 and 180 or p_cancel not between 0 and 720
  or p_max_off not between 0 and 20 or p_capacity not between 1 and 20 then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726001);
 perform public.spa_settings_save(p_open,p_close,p_days,p_auto,p_cancel);
 perform public.spa_schedule_policy_save(p_max_off);
 perform public.spa_booking_capacity_save(p_capacity);
end $$;
revoke all on function public.spa_booking_policy_save(int,int,int,boolean,int,int,int) from public,anon,authenticated;
grant execute on function public.spa_booking_policy_save(int,int,int,boolean,int,int,int) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
