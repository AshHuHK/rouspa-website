begin;

-- Canonicalize the unordered row collections emitted by the export while
-- preserving array order inside business JSON (sale payloads and source packets).
-- Volatile exported_at is removed by reset_backup_fingerprint below.
create or replace function spa_private.canonical_reset_json(p_value jsonb,p_path text[] default '{}'::text[]) returns jsonb
language plpgsql immutable set search_path='' as $$
declare result jsonb; sort_elements boolean;
begin
 if p_value is null then return null; end if;
 if jsonb_typeof(p_value)='object' then
  select coalesce(jsonb_object_agg(key,spa_private.canonical_reset_json(value,p_path||key)),'{}'::jsonb)
  into result from jsonb_each(p_value);
  return result;
 elsif jsonb_typeof(p_value)='array' then
  sort_elements:=(cardinality(p_path)=1 and p_path[1]=any(array[
   'appointments','checkouts','appointment_reviews','appointment_wallet_entries','appointment_package_entries',
   'appointment_cash_entries','booking_actions','appointment_staff_changes','legacy_imports','orders',
   'order_inventory_entries','order_cash_entries','reviews','feedback','payroll_runs','payroll_source_snapshots',
   'time_entries','overtime_entries','payroll_adjustments','attendance','attendance_events','attendance_requests',
   'coupons','sale_requests','refund_requests','expenses'
  ]::text[])) or (cardinality(p_path)=2 and p_path[1]=any(array['orders','payroll_runs']::text[]) and p_path[2]='items');
  if sort_elements then
   select coalesce(jsonb_agg(normalized order by normalized::text),'[]'::jsonb)
   into result from (select spa_private.canonical_reset_json(value,p_path) normalized from jsonb_array_elements(p_value)) elements;
  else
   select coalesce(jsonb_agg(normalized order by ordinal),'[]'::jsonb)
   into result from (select spa_private.canonical_reset_json(value,p_path) normalized,ordinal from jsonb_array_elements(p_value) with ordinality items(value,ordinal)) elements;
  end if;
  return result;
 end if;
 return p_value;
end $$;

create or replace function spa_private.reset_backup_fingerprint(p_export jsonb) returns text
language sql immutable set search_path='' as $$
 select md5('spa-reset-backup-v1:'||spa_private.canonical_reset_json(p_export-'exported_at','{}'::text[])::text)
$$;
revoke all on function spa_private.canonical_reset_json(jsonb,text[]),spa_private.reset_backup_fingerprint(jsonb) from public,anon,authenticated;

-- Export every appointment-chain artifact, including historical staff changes.
-- The existing reset locks serialize backup capture with the reset and the
-- workflow writers that share this lock family.
create or replace function public.spa_backup_export(p_scope text,p_from date default null,p_to date default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b record;
begin
 perform spa_private.require_permission('settings.manage');
 if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 select * into b from spa_private.reset_bounds(p_from,p_to);
 return jsonb_build_object('exported_at',now(),'scope',p_scope,'from',p_from,'to',p_to,'preview',public.spa_reset_preview(p_scope,p_from,p_to),
  'appointments',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_appointments a where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'checkouts',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(ch)) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_reviews',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_wallet_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_wallet_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_package_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_package_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_cash_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'booking_actions',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_booking_actions e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_staff_changes',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(x)) from public.spa_appointment_staff_changes x join public.spa_appointments a on a.id=x.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'legacy_imports',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(li)) from public.spa_legacy_imports li join public.spa_appointments a on a.id=li.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'orders',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_order_items i where i.order_id=o.id))) from public.spa_orders o where coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_inventory_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(i)) from public.spa_inventory_entries i join public.spa_orders o on o.id=i.reference_id where i.reference_type='order' and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_cash_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_orders o on o.request_id=e.request_id where e.category in ('product','pos') and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'reviews',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r where r.created_at>=b.first_time and r.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'feedback',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(f)) from public.spa_feedback f where f.created_at>=b.first_time and f.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'payroll_runs',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_payroll_items i where i.run_id=r.id))) from public.spa_payroll_runs r where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'payroll_source_snapshots',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(snap)) from public.spa_payroll_source_snapshots snap join public.spa_payroll_runs r on r.id=snap.run_id where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'time_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_time_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'overtime_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_overtime_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'payroll_adjustments',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_payroll_adjustments e where p_from is null or e.period_start between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_attendance a where p_from is null or a.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance_events',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where p_from is null or a.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance_requests',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_attendance_requests r where p_from is null or r.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'coupons',coalesce((select jsonb_agg(to_jsonb(c)) from public.spa_coupons c where (p_scope in ('appointments','all') and exists(select 1 from public.spa_appointments a where (a.id=c.appointment_id or a.id=(select appointment_id from public.spa_checkouts where id=c.checkout_id)) and (p_from is null or a.business_date between p_from and p_to))) or (p_scope in ('orders','all') and exists(select 1 from public.spa_orders o where o.id=c.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))),'[]'),
  'sale_requests',coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_sale_requests r where (p_scope in ('appointments','all') and exists(select 1 from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.id=r.checkout_id and (p_from is null or a.business_date between p_from and p_to))) or (p_scope in ('orders','all') and exists(select 1 from public.spa_orders o where o.id=r.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))),'[]'),
  'refund_requests',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_refund_requests r join public.spa_checkouts ch on ch.id=r.checkout_id join public.spa_appointments a on a.id=ch.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'expenses',case when p_scope in ('expenses','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e where e.category='expense' and e.created_at>=b.first_time and e.created_at<b.last_time),'[]') else '[]'::jsonb end);
end $$;

create or replace function public.spa_reset_backup_prepare(p_scope text,p_from date default null,p_to date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare backup jsonb;
begin
 perform spa_private.require_permission('settings.manage');
 if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 backup:=public.spa_backup_export(p_scope,p_from,p_to);
 return jsonb_build_object('backup',backup,'fingerprint',spa_private.reset_backup_fingerprint(backup));
end $$;

create or replace function public.spa_reset_business_data_guarded(p_scope text,p_from date,p_to date,p_confirmation text,p_fingerprint text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_export jsonb;
begin
 perform spa_private.require_permission('settings.manage');
 if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_confirmation<>'RESET' or p_fingerprint is null or p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'RESET_CONFIRMATION_REQUIRED'; end if;
 perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 current_export:=public.spa_backup_export(p_scope,p_from,p_to);
 if spa_private.reset_backup_fingerprint(current_export) is distinct from p_fingerprint then raise exception 'BACKUP_STALE'; end if;
 return public.spa_reset_business_data(p_scope,p_from,p_to,p_confirmation);
end $$;

revoke all on function public.spa_reset_backup_prepare(text,date,date),public.spa_reset_business_data_guarded(text,date,date,text,text) from public,anon,authenticated;
grant execute on function public.spa_reset_backup_prepare(text,date,date),public.spa_reset_business_data_guarded(text,date,date,text,text) to authenticated,service_role;

-- Reviews and anonymous feedback can be submitted while a reset is being
-- confirmed. Join their writes to the same lock family so a guarded backup
-- cannot miss a newly submitted deletion candidate.
create or replace function public.spa_submit_review(p_token uuid,p_rating int,p_comment text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; inserted_count int;
begin
 perform pg_advisory_xact_lock(726001);
 select ap.* into a from public.spa_appointments ap join public.spa_customers c on c.id=ap.customer_id
 where ap.review_token=p_token and ap.status='completed' and c.status='active' and c.archived_at is null for update of ap,c;
 if not found then raise exception 'REVIEW_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>1000 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_reviews(appointment_id,rating,comment) values(a.id,p_rating,btrim(p_comment)) on conflict(appointment_id) do nothing;
 get diagnostics inserted_count=row_count;
 if inserted_count=1 then
  insert into public.spa_coupons(customer_id,appointment_id,code) values(a.customer_id,a.id,'ROU50-'||upper(substr(replace(a.id::text,'-',''),1,12))) on conflict(appointment_id) do nothing;
 end if;
end $$;

create or replace function public.spa_submit_feedback(p_message text) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(726001);
 if length(btrim(coalesce(p_message,''))) not between 5 and 500 then raise exception 'INVALID_INPUT'; end if;
 if (select count(*) from public.spa_feedback where created_at>now()-interval '1 minute')>=20 then raise exception 'RATE_LIMIT'; end if;
 insert into public.spa_feedback(message) values(btrim(p_message));
end $$;

create or replace function public.spa_moderate(p_kind text,p_id uuid,p_status text,p_reply text default '') returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('reviews.manage'); perform pg_advisory_xact_lock(726001);
 if p_kind='review' and p_status in ('pending','published','hidden') and length(p_reply)<=1000 then update public.spa_reviews set status=p_status,reply=p_reply where id=p_id;
 elsif p_kind='feedback' and p_status in ('unread','read','resolved') then update public.spa_feedback set status=p_status where id=p_id;
 else raise exception 'INVALID_INPUT'; end if;
 if not found then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit(p_kind||'.moderated',p_id::text,jsonb_build_object('status',p_status));
end $$;

-- The legacy monetary RPCs previously returned success for any reused request
-- id. Normalize operator-entered text, lock the same refund namespace, and
-- accept a retry only if every business input matches the persisted ledger.
create or replace function spa_private.shared_financial_request_conflict(p_request uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.spa_appointments where request_id=p_request)
  or exists(select 1 from public.spa_checkouts where request_id=p_request)
  or exists(select 1 from public.spa_orders where request_id=p_request)
  or exists(select 1 from public.spa_sale_requests where request_id=p_request)
  or exists(select 1 from public.spa_refund_requests where request_id=p_request)
$$;
revoke all on function spa_private.shared_financial_request_conflict(uuid) from public,anon,authenticated;

create or replace function public.spa_topup(p_request uuid,p_customer uuid,p_cents bigint,p_method text,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare prior public.spa_wallet_entries; cash_entry public.spa_cash_entries; normalized_note text:=btrim(coalesce(p_note,''));
begin
 perform spa_private.require_permission('customers.manage'); perform pg_advisory_xact_lock(726001);
 perform 1 from public.spa_customers where id=p_customer and archived_at is null for update;
 if not found or p_request is null or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method is null or p_method not in ('cash','card','transfer') or length(normalized_note)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from public.spa_wallet_entries where request_id=p_request for update;
 if found then
  select * into cash_entry from public.spa_cash_entries where request_id=p_request and category='topup' for update;
  if prior.kind<>'topup' or prior.customer_id is distinct from p_customer or prior.amount_cents is distinct from p_cents or btrim(prior.note) is distinct from normalized_note
   or not found or cash_entry.customer_id is distinct from p_customer or cash_entry.amount_cents is distinct from p_cents or cash_entry.method is distinct from p_method or btrim(cash_entry.note) is distinct from normalized_note
   or (select count(*) from public.spa_cash_entries where request_id=p_request)<>1 or exists(select 1 from public.spa_packages where request_id=p_request)
   or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 if exists(select 1 from public.spa_packages where request_id=p_request) or exists(select 1 from public.spa_cash_entries where request_id=p_request) or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'topup',p_request,normalized_note,auth.uid());
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'topup',p_method,normalized_note,auth.uid());
 update public.spa_customers set customer_type='member' where id=p_customer;
 perform spa_private.audit('wallet.topup',p_customer::text,jsonb_build_object('cents',p_cents));
end $$;

create or replace function public.spa_wallet_adjust(p_request uuid,p_customer uuid,p_cents bigint,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare balance bigint; prior public.spa_wallet_entries; normalized_note text:=btrim(coalesce(p_note,''));
begin
 perform spa_private.require_permission('customers.manage'); perform pg_advisory_xact_lock(726001);
 perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_request is null or p_cents is null or p_cents=0 or abs(p_cents)>100000000 or length(normalized_note)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from public.spa_wallet_entries where request_id=p_request for update;
 if found then
  if prior.kind<>'adjustment' or prior.customer_id is distinct from p_customer or prior.amount_cents is distinct from p_cents or btrim(prior.note) is distinct from normalized_note
   or exists(select 1 from public.spa_cash_entries where request_id=p_request) or exists(select 1 from public.spa_packages where request_id=p_request)
   or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 if exists(select 1 from public.spa_cash_entries where request_id=p_request) or exists(select 1 from public.spa_packages where request_id=p_request) or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 select coalesce(sum(amount_cents),0) into balance from public.spa_wallet_entries where customer_id=p_customer;
 if balance+p_cents<0 then raise exception 'INSUFFICIENT_CREDITS'; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'adjustment',p_request,normalized_note,auth.uid());
 perform spa_private.audit('wallet.adjusted',p_customer::text,jsonb_build_object('cents',p_cents,'reason',normalized_note));
end $$;

create or replace function public.spa_package_sell(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text) returns void
language plpgsql security definer set search_path='' as $$
declare prior public.spa_packages; cash_entry public.spa_cash_entries; normalized_name text:=btrim(coalesce(p_name,''));
begin
 perform spa_private.require_permission('customers.manage'); perform pg_advisory_xact_lock(726001);
 perform 1 from public.spa_customers where id=p_customer and archived_at is null for update;
 if not found or p_request is null or p_sessions not between 1 and 200 or p_expires is null or p_expires<=now() or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method is null or p_method not in ('cash','card','transfer') or length(normalized_name)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from public.spa_packages where request_id=p_request for update;
 if found then
  select * into cash_entry from public.spa_cash_entries where request_id=p_request and category='package' for update;
  if prior.customer_id is distinct from p_customer or prior.service_id is distinct from p_service or btrim(prior.name) is distinct from normalized_name or prior.sessions is distinct from p_sessions or prior.paid_cents is distinct from p_cents or prior.expires_at is distinct from p_expires
   or not found or cash_entry.customer_id is distinct from p_customer or cash_entry.amount_cents is distinct from p_cents or cash_entry.method is distinct from p_method or btrim(cash_entry.note) is distinct from normalized_name
   or (select count(*) from public.spa_cash_entries where request_id=p_request)<>1 or exists(select 1 from public.spa_wallet_entries where request_id=p_request)
   or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 if exists(select 1 from public.spa_wallet_entries where request_id=p_request) or exists(select 1 from public.spa_cash_entries where request_id=p_request) or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 insert into public.spa_packages(customer_id,service_id,name,sessions,paid_cents,expires_at,request_id) values(p_customer,p_service,normalized_name,p_sessions,p_cents,p_expires,p_request);
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'package',p_method,normalized_name,auth.uid());
 update public.spa_customers set customer_type='member' where id=p_customer;
 perform spa_private.audit('package.sold',p_customer::text,jsonb_build_object('sessions',p_sessions,'cents',p_cents));
end $$;

create or replace function public.spa_expense(p_request uuid,p_cents bigint,p_method text,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare prior public.spa_cash_entries; normalized_note text:=btrim(coalesce(p_note,''));
begin
 perform spa_private.require_permission('finance.manage'); perform pg_advisory_xact_lock(726001);
 if p_request is null or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method is null or p_method not in ('cash','card','transfer') or length(normalized_note)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from public.spa_cash_entries where request_id=p_request and category='expense' for update;
 if found then
  if prior.amount_cents is distinct from -p_cents or prior.method is distinct from p_method or btrim(prior.note) is distinct from normalized_note or prior.customer_id is not null or prior.appointment_id is not null
   or (select count(*) from public.spa_cash_entries where request_id=p_request)<>1 or exists(select 1 from public.spa_wallet_entries where request_id=p_request) or exists(select 1 from public.spa_packages where request_id=p_request)
   or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 if exists(select 1 from public.spa_cash_entries where request_id=p_request) or exists(select 1 from public.spa_wallet_entries where request_id=p_request) or exists(select 1 from public.spa_packages where request_id=p_request) or spa_private.shared_financial_request_conflict(p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 insert into public.spa_cash_entries(request_id,amount_cents,category,method,note,created_by) values(p_request,-p_cents,'expense',p_method,normalized_note,auth.uid());
 perform spa_private.audit('expense.recorded',p_request::text,jsonb_build_object('cents',p_cents,'note',normalized_note));
end $$;

notify pgrst,'reload schema';
commit;
