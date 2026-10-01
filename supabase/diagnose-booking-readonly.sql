-- ROU SPA: run in Supabase SQL Editor as the project owner.
-- Read-only diagnostics. No inserts, updates, deletes or grants.
-- No customer names, phones or private booking tokens are returned.
begin transaction read only;

-- 1) Compare this project reference with the browser Network request hostname.
-- Browser front and admin must target the same project and deployment.
select (now() at time zone 'Asia/Taipei')::date as taiwan_today,
       to_regclass('public.spa_appointments') as current_table,
       to_regclass('public.bookings') as legacy_table,
       to_regclass('public.spa_legacy_imports') as legacy_import_table;

-- 2) Confirm the current RPC signatures exist.
select n.nspname as schema_name,p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('spa_create_booking','spa_admin_bookings','spa_session','spa_catalog')
order by p.proname;

-- 3) Day-by-day counts over the allowed public booking horizon.
-- Run steps 3-5 only after step 1 confirms the current table exists.
select business_date,status,count(*) as appointment_count
from public.spa_appointments
where business_date between (now() at time zone 'Asia/Taipei')::date
  and (now() at time zone 'Asia/Taipei')::date+30
group by business_date,status order by business_date,status;

-- 4) Locate recent booking references and compare service day vs creation time.
-- Compare the reference shown to the customer; do not confuse created_at with service date.
select reference,business_date,status,
       starts_at at time zone 'Asia/Taipei' as service_time_tw,
       created_at at time zone 'Asia/Taipei' as submitted_time_tw
from public.spa_appointments order by created_at desc limit 20;

-- 5) Verify role distribution; a therapist sees only their own bookings.
select role,active,count(*) as account_count
from public.spa_roles group by role,active order by role,active;

-- 6) Optional: once the import table exists, check whether legacy rows need review.
-- select outcome,count(*) from public.spa_legacy_imports group by outcome;
-- Legacy import is one-time: later inserts into public.bookings are not imported automatically.
rollback;
