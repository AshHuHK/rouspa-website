-- Run AFTER migration, owner setup, legacy import review and new website deployment.
-- Retains every legacy record, but prevents the old anonymous admin API from reading or changing them.
begin;
do $$ declare fn record; begin
 if to_regclass('public.bookings') is not null then
  alter table public.bookings enable row level security;
  revoke all on public.bookings from anon,authenticated;
 end if;
 if to_regclass('public.feedback') is not null then
  alter table public.feedback enable row level security;
  revoke all on public.feedback from anon,authenticated;
 end if;
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('get_all_booked_slots','get_booked_slots') loop
  execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
