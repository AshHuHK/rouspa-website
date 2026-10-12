-- One committed phone/name attempt budget protects all public identity checks.
-- Structured failures commit that budget; API clients must treat {error:CODE}
-- as failures, never as successful booking or login receipts.
begin;

create or replace function spa_private.reserve_public_identity_attempt(p_phone text) returns boolean
language plpgsql security definer set search_path='' as $$
declare instant timestamptz; attempt int; key_hash text:=md5('identity:'||p_phone);
begin
 perform pg_advisory_xact_lock(726003);
 instant:=clock_timestamp();
 insert into public.spa_booking_lookup_limits(phone_hash,window_start,attempts) values(key_hash,instant,1)
 on conflict(phone_hash) do update set
  window_start=case when spa_booking_lookup_limits.window_start<=instant-interval '10 minutes' then instant else spa_booking_lookup_limits.window_start end,
  attempts=case when spa_booking_lookup_limits.window_start<=instant-interval '10 minutes' then 1 else least(spa_booking_lookup_limits.attempts+1,11) end
 returning attempts into attempt;
 delete from public.spa_booking_lookup_limits where window_start<instant-interval '1 day';
 return attempt<=10;
end $$;

create or replace function public.spa_create_booking(p_request uuid,p_service uuid,p_date date,p_start timestamptz,p_staff uuid,p_name text,p_phone text,p_tea int default 0,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg public.spa_settings; hours record; svc public.spa_services; slot record; customer public.spa_customers; booking public.spa_appointments; tel text; minute int; assigned_name text; predicted int; attention boolean; failure text;
begin
 perform pg_advisory_xact_lock(726001); tel:=spa_private.phone(p_phone);
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 80 or tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_tea is null or p_tea not between 0 and 4 or length(coalesce(p_note,''))>1000 then raise exception 'INVALID_INPUT'; end if;
 -- A receipt retry is a capability-bearing replay. Verify the complete existing
 -- payload before the current catalogue/date checks and before charging a guess.
 select * into booking from public.spa_appointments where request_id=p_request;
 if found then
  select * into customer from public.spa_customers where id=booking.customer_id;
  if customer.phone is distinct from tel or lower(btrim(customer.name)) is distinct from lower(btrim(p_name))
   or booking.service_id is distinct from p_service or booking.business_date is distinct from p_date
   or booking.starts_at is distinct from p_start or booking.requested_staff_id is distinct from p_staff
   or booking.tea_code is distinct from p_tea or booking.note is distinct from coalesce(p_note,'')
   then raise exception 'REQUEST_CONFLICT'; end if;
  if customer.status<>'active' or customer.archived_at is not null then return jsonb_build_object('error','CUSTOMER_IDENTITY_INVALID'); end if;
  select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
  return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference,
   'capacity_attention_required',spa_private.capacity_exceeded(booking.id),'capacity_count',booking.capacity_count_snapshot,'capacity_limit',coalesce(booking.capacity_limit_snapshot,(select simultaneous_capacity from public.spa_settings limit 1)));
 end if;
 select * into cfg from public.spa_settings; select * into hours from spa_private.business_window(p_date);
 select * into svc from public.spa_services where id=p_service and active and status='active' and online_booking_enabled;
 if not found then raise exception 'INVALID_SERVICE'; end if;
 minute:=floor(extract(epoch from ((p_start at time zone cfg.timezone)-p_date::timestamp))/60)::int;
 if p_date is null or p_start is null or not coalesce(hours.is_open,false) or p_date<(now() at time zone cfg.timezone)::date or p_date>spa_private.booking_last_date() or p_start<=now()+interval '30 minutes' or minute<hours.opening_minute or minute>=hours.closing_minute or (minute-hours.opening_minute)%cfg.slot_minutes<>0 or date_trunc('minute',p_start)<>p_start then raise exception 'INVALID_DATE'; end if;
 -- Reserve outside the subtransaction: an identity failure or an unavailable
 -- slot must not roll the attempt back and reopen an unlimited guessing route.
 if not spa_private.reserve_public_identity_attempt(tel) then return jsonb_build_object('error','RATE_LIMIT'); end if;
 select * into customer from public.spa_customers where phone=tel for update;
 if found and (lower(btrim(customer.name)) is distinct from lower(btrim(p_name)) or customer.status<>'active' or customer.archived_at is not null)
  then return jsonb_build_object('error','CUSTOMER_IDENTITY_INVALID'); end if;
 begin
 if customer.id is not null and (select count(*) from public.spa_appointments where customer_id=customer.id and created_at>now()-interval '24 hours')>=5 then raise exception 'RATE_LIMIT'; end if;
 select * into slot from spa_private.candidates(p_service,p_date,p_start,p_staff) limit 1;
 if not found then raise exception 'SLOT_TAKEN' using errcode='23P01'; end if;
 predicted:=spa_private.capacity_peak(p_start,slot.ends_at,null)+1; attention:=predicted>cfg.simultaneous_capacity;
 if customer.id is null then insert into public.spa_customers(name,phone) values(btrim(p_name),tel) returning * into customer; end if;
 insert into public.spa_appointments(request_id,customer_id,staff_id,requested_staff_id,booking_preference,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note,capacity_attention_required,capacity_count_snapshot,capacity_limit_snapshot)
 values(p_request,customer.id,slot.staff_id,p_staff,case when p_staff is null then 'any' else 'designated' end,null,p_service,p_date,p_start,slot.ends_at,slot.blocked_until,case when attention or not cfg.auto_confirm then 'pending' else 'confirmed' end,svc.name,svc.price_cents,p_tea,(array[0,12000,15000,12000,18000])[p_tea+1],coalesce(p_note,''),attention,predicted,cfg.simultaneous_capacity) returning * into booking;
 select s.name into assigned_name from public.spa_staff s where s.id=booking.staff_id;
 perform spa_private.audit('booking.created',booking.id::text,jsonb_build_object('source',case when spa_private.has_permission('appointments.manage') then 'admin' else 'website' end,'preference',booking.booking_preference,'requested_staff_id',p_staff,'assigned_staff_id',booking.staff_id,'capacity_count',predicted,'capacity_limit',cfg.simultaneous_capacity,'capacity_attention_required',attention));
 return jsonb_build_object('reference',booking.reference,'status',booking.status,'manage_token',booking.manage_token,'staff_id',booking.staff_id,'staff_name',assigned_name,'booking_preference',booking.booking_preference,'capacity_attention_required',attention,'capacity_count',predicted,'capacity_limit',cfg.simultaneous_capacity);
 exception when others then
  failure:=sqlerrm;
  if failure in ('RATE_LIMIT','SLOT_TAKEN','PAYROLL_LOCKED') then return jsonb_build_object('error',failure); end if;
  raise;
 end;
end $$;

create or replace function public.spa_lookup_bookings(p_phone text,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare tel text:=spa_private.phone(p_phone); customer uuid; access uuid; expiry timestamptz:=now()+interval '20 minutes';
begin
 if tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if not spa_private.reserve_public_identity_attempt(tel) then return jsonb_build_object('error','RATE_LIMIT'); end if;
 select c.id into customer from public.spa_customers c
 where c.phone=tel and lower(btrim(c.name))=lower(btrim(p_name)) and c.status='active' and c.archived_at is null;
 if customer is null then return jsonb_build_object('error','CUSTOMER_IDENTITY_INVALID'); end if;
 delete from public.spa_booking_access where expires_at<=now();
 insert into public.spa_booking_access(customer_id,expires_at) values(customer,expiry) returning token into access;
 return jsonb_build_object('access_token',access,'expires_at',expiry,'appointments',public.spa_customer_booking_list(access));
end $$;

create or replace function public.spa_member_login(p_phone text,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare tel text:=spa_private.phone(p_phone); customer uuid; access uuid; expiry timestamptz:=now()+interval '2 hours';
begin
 if tel is null or tel !~ '^\+?[0-9]{8,15}$' or p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if not spa_private.reserve_public_identity_attempt(tel) then return jsonb_build_object('error','RATE_LIMIT'); end if;
 select c.id into customer from public.spa_customers c
 where c.phone=tel and lower(btrim(c.name))=lower(btrim(p_name)) and c.customer_type='member' and c.status='active' and c.archived_at is null;
 if customer is null then return jsonb_build_object('error','CUSTOMER_IDENTITY_INVALID'); end if;
 delete from public.spa_booking_access where expires_at<=now();
 insert into public.spa_booking_access(customer_id,expires_at) values(customer,expiry) returning token into access;
 return jsonb_build_object('access_token',access,'expires_at',expiry,'member',spa_private.member_snapshot(customer));
end $$;

-- Long-lived private links must obey the same customer revocation boundary
-- as short-lived access tokens. Missing and revoked tokens have identical results.
create or replace function public.spa_manage_booking(p_token uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('reference',a.reference,'status',a.status,'service_name',a.service_name,'starts_at',a.starts_at,'ends_at',a.ends_at,'price_cents',a.price_cents+a.tea_cents)
 from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id
 where a.manage_token=p_token and c.status='active' and c.archived_at is null
$$;

create or replace function public.spa_cancel_booking(p_token uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; hours int;
begin
 perform pg_advisory_xact_lock(726001);
 select ap.* into a from public.spa_appointments ap join public.spa_customers c on c.id=ap.customer_id
 where ap.manage_token=p_token and c.status='active' and c.archived_at is null for update of ap,c;
 select cancellation_hours into hours from public.spa_settings;
 if not found or a.id is null then raise exception 'NOT_FOUND'; end if;
 if a.status='cancelled' then return; end if;
 if a.status not in ('pending','confirmed') or a.starts_at<now()+make_interval(hours=>hours) then raise exception 'CANCELLATION_CUTOFF'; end if;
 if length(btrim(p_reason))=0 then raise exception 'REASON_REQUIRED'; end if;
 update public.spa_appointments set status='cancelled',cancellation_reason=p_reason where id=a.id;
 perform spa_private.audit('booking.customer_cancelled',a.id::text,jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.spa_review_context(p_token uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('reference',a.reference,'service_name',a.service_name,'therapist',s.name,
  'submitted',exists(select 1 from public.spa_reviews where appointment_id=a.id),
  'reward_cents',5000,
  'coupon',(select jsonb_build_object('code',c.code,'amount_cents',c.amount_cents,'expires_at',c.expires_at) from public.spa_coupons c where c.appointment_id=a.id))
 from public.spa_appointments a join public.spa_staff s on s.id=a.staff_id
 join public.spa_customers customer on customer.id=a.customer_id
 where a.review_token=p_token and a.status='completed' and customer.status='active' and customer.archived_at is null
$$;

create or replace function public.spa_submit_review(p_token uuid,p_rating int,p_comment text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; inserted_count int;
begin
 perform pg_advisory_xact_lock(726001);
 select ap.* into a from public.spa_appointments ap join public.spa_customers c on c.id=ap.customer_id
 where ap.review_token=p_token and ap.status='completed' and c.status='active' and c.archived_at is null for update of ap,c;
 if not found then raise exception 'REVIEW_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>1000 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_reviews(appointment_id,rating,comment) values(a.id,p_rating,btrim(p_comment))
 on conflict(appointment_id) do nothing;
 get diagnostics inserted_count=row_count;
 if inserted_count=1 then
  insert into public.spa_coupons(customer_id,appointment_id,code)
  values(a.customer_id,a.id,'ROU50-'||upper(substr(replace(a.id::text,'-',''),1,12)))
  on conflict(appointment_id) do nothing;
 end if;
end $$;

-- Existing associations remain usable while owners migrate legacy HTTP photos.
-- New or changed associations must be credential-free absolute HTTPS URLs.
create or replace function spa_private.product_image_url_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and new.image_url is not distinct from old.image_url then return new; end if;
 if coalesce(new.image_url,'')<>'' and (
  new.image_url !~* '^https://[^/?#[:space:]@]+([/?#][^[:space:]]*)?$'
  or position(chr(92) in new.image_url)>0
 ) then raise exception 'INVALID_PRODUCT_IMAGE_URL'; end if;
 return new;
end $$;
drop trigger if exists spa_product_image_url_guard on public.spa_products;
create trigger spa_product_image_url_guard before insert or update of image_url on public.spa_products
 for each row execute function spa_private.product_image_url_guard();

-- PostgreSQL gives newly created functions PUBLIC EXECUTE, including wrappers
-- recreated after a rename. Private definer helpers are internal capabilities;
-- only the two policy predicates below need authenticated execution.
do $$ declare fn record; begin
 for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='spa_private' loop
  execute format('revoke all on function %s from public,anon,authenticated',fn.signature);
 end loop;
end $$;
grant execute on function spa_private.product_media_upload_allowed(text,text),spa_private.can_receive_operations() to authenticated;

alter table public.spa_service_addon_targets enable row level security;
revoke all on public.spa_service_addon_targets from public,anon,authenticated;
grant all on public.spa_service_addon_targets to service_role;

revoke all on function public.spa_create_booking(uuid,uuid,date,timestamptz,uuid,text,text,int,text),public.spa_lookup_bookings(text,text),public.spa_member_login(text,text) from public,anon,authenticated;
grant execute on function public.spa_create_booking(uuid,uuid,date,timestamptz,uuid,text,text,int,text),public.spa_lookup_bookings(text,text),public.spa_member_login(text,text) to anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
