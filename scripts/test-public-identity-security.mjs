import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

process.on('uncaughtException', error => { console.error(error.message); if (error.where) console.error(error.where); process.exit(1); });
const db = new PGlite();
let checks = 0;
const equal = (actual, expected, label) => { assert.deepEqual(actual, expected, label); checks++; };
const check = (value, label) => { assert.ok(value, label); checks++; };
await db.exec(`
 create role anon; create role authenticated; create role service_role;
 create schema auth; create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;
 grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
 -- Test with permissive inherited table grants as well as PostgreSQL's default
 -- PUBLIC function execution: migrations must explicitly establish boundaries.
 alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
`);
const directory = new URL('../supabase/migrations/', import.meta.url);
const securityMigration = '202610120001_public_identity_security.sql';
const files = (await readdir(directory)).filter(file => file.endsWith('.sql')).sort();
for (const file of files.filter(file => file < securityMigration)) await db.exec(await readFile(new URL(file, directory), 'utf8'));
const legacyProduct = (await db.query("select id from spa_products limit 1")).rows[0].id;
await db.query("update spa_products set image_url='http://legacy.example.test/photo.jpg' where id=$1", [legacyProduct]);
for (const file of files.filter(file => file >= securityMigration)) await db.exec(await readFile(new URL(file, directory), 'utf8'));

const tableFailures = (await db.query(`
 select n.nspname,c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.relkind='r' and (n.nspname='spa_private' or (n.nspname='public' and c.relname like 'spa_%'))
 and (not c.relrowsecurity or has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
`)).rows;
equal(tableFailures, [], 'all business tables use RLS and deny every direct browser-role table privilege');
const privateExecutables = (await db.query(`
 select p.oid::regprocedure::text signature,has_function_privilege('anon',p.oid,'execute') anon,
 has_function_privilege('authenticated',p.oid,'execute') authenticated
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='spa_private' and p.prosecdef
 and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')) order by signature
`)).rows;
equal(privateExecutables, [
 { signature: 'spa_private.can_receive_operations()', anon: false, authenticated: true },
 { signature: 'spa_private.product_media_upload_allowed(text,text)', anon: false, authenticated: true }
], 'only the explicit safe authenticated policy predicates expose private definer execution');
equal((await db.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.prosecdef and (n.nspname='spa_private' or p.proname like 'spa_%')
 and not coalesce(p.proconfig @> array['search_path=""'],false)`)).rows, [], 'every business definer has an empty search path');

async function call(name, args = [], role = 'anon') {
 await db.exec('begin');
 try {
  await db.exec(`set local role ${role}`);
  const result = (await db.query(`select public.${name}(${args.map((_, index) => '$' + (index + 1)).join(',')}) result`, args)).rows[0].result;
  await db.exec('commit');
  return result;
 } catch (error) { await db.exec('rollback'); throw error; }
}
const denied = async (operation, pattern, label) => { await assert.rejects(operation, pattern, label); checks++; };
const identityError = { error: 'CUSTOMER_IDENTITY_INVALID' };
const rateError = { error: 'RATE_LIMIT' };
const phone = '0911990001';
const customer = (await db.query("insert into spa_customers(name,phone,customer_type) values('Synthetic identity member',$1,'member') returning id", [phone])).rows[0].id;
const date = (await db.query("select ((now() at time zone 'Asia/Taipei')::date+2)::text date")).rows[0].date;
const service = (await db.query("select id from spa_services where active and status='active' and online_booking_enabled order by display_order limit 1")).rows[0].id;
const staff = (await db.query("select s.id from spa_staff s join spa_staff_services sk on sk.staff_id=s.id where sk.service_id=$1 and sk.enabled and s.active and s.is_bookable and s.employment_status='active' and s.archived_at is null limit 1", [service])).rows[0].id;
await db.query("insert into spa_business_day_overrides(business_date,is_open,opening_minute,closing_minute,note) values($1,true,600,1320,'Synthetic identity test') on conflict(business_date) do update set is_open=true,opening_minute=600,closing_minute=1320", [date]);
await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note) values($1,$2,true,600,1320,'Synthetic identity test') on conflict(staff_id,business_date) do update set is_working=true,start_minute=600,end_minute=1320", [staff,date]);
const bookingArgs = (targetPhone = phone, name = 'Synthetic identity member', hour = 10, request = randomUUID()) => [request, service, date, `${date}T${String(hour).padStart(2,'0')}:00:00+08:00`, staff, name, targetPhone, 0, ''];
const attempts = async targetPhone => Number((await db.query("select coalesce((select attempts from spa_booking_lookup_limits where phone_hash=md5('identity:'||$1)),0) attempts", [targetPhone])).rows[0].attempts);

for (const [targetPhone,name] of [[phone,'Wrong name'],[phone,'Synthetic identity member'],['0911990099','Unknown member']]) {
 const invalidService = bookingArgs(targetPhone,name); invalidService[1] = null;
 await denied(() => call('spa_create_booking',invalidService), /INVALID_SERVICE/, 'service validation has identical errors independent of identity');
 const invalidDate = bookingArgs(targetPhone,name); invalidDate[2] = null; invalidDate[3] = null;
 await denied(() => call('spa_create_booking',invalidDate), /INVALID_DATE/, 'date validation has identical errors independent of identity');
}
equal(await attempts(phone),0,'invalid service/date cannot expose or charge an identity check');
for (let index=0; index<9; index++) {
 const result = index%3===0 ? await call('spa_create_booking',bookingArgs(phone,'Wrong name'))
  : await call(index%3===1?'spa_lookup_bookings':'spa_member_login',[phone,'Wrong name']);
 equal(result,identityError,'failed identities use the same committed structured error');
 equal(await attempts(phone),index+1,'each identity failure commits one shared attempt');
}
const lookup = await call('spa_lookup_bookings',['0911-990-001',' synthetic IDENTITY member ']);
check(lookup.access_token && Array.isArray(lookup.appointments),'normalized name and phone succeed on the tenth shared attempt');
equal(await attempts(phone),10,'successful lookup also consumes the shared budget');
equal(await call('spa_create_booking',bookingArgs()),rateError,'booking cannot bypass an exhausted lookup/member budget');
equal(await call('spa_member_login',[phone,'Synthetic identity member']),rateError,'all endpoints share the exhausted budget');
equal(await attempts(phone),11,'limited retries remain capped and committed');
await db.query("update spa_booking_lookup_limits set window_start=clock_timestamp()-interval '11 minutes' where phone_hash=md5('identity:'||$1)",[phone]);
const member = await call('spa_member_login',[phone,'Synthetic identity member']);
check(member.access_token && member.member.profile.id===customer,'the shared budget resets after ten minutes without changing member access');
equal(await attempts(phone),1,'expired window restarts at one');
check(Math.abs((Date.parse(member.expires_at)-Date.now())/3600000-2)<0.02,'member access remains two hours');
check(Math.abs((Date.parse(lookup.expires_at)-Date.now())/60000-20)<1,'booking access remains twenty minutes');

for (const mode of ['blocked','archived','unknown']) {
 if(mode==='blocked') await db.query("update spa_customers set status='blocked' where id=$1",[customer]);
 if(mode==='archived') await db.query("update spa_customers set status='active',archived_at=now() where id=$1",[customer]);
 const targetPhone=mode==='unknown'?'0911990088':phone;
 for (const rpc of ['spa_lookup_bookings','spa_member_login']) equal(await call(rpc,[targetPhone,'Synthetic identity member']),identityError,'unknown and unavailable identities are indistinguishable');
 if(mode!=='unknown') equal(await call('spa_create_booking',bookingArgs()),identityError,'blocked and archived bookings share the mismatch error');
}
await db.query("update spa_customers set status='active',archived_at=null where id=$1",[customer]);
await db.query("delete from spa_booking_lookup_limits where phone_hash=md5('identity:'||$1)",[phone]);
const firstArgs=bookingArgs();
const receipt=await call('spa_create_booking',firstArgs);
check(receipt.manage_token && receipt.reference,'valid existing-member booking succeeds');
const beforeCollision=await attempts(phone);
equal(await call('spa_create_booking',bookingArgs()),{error:'SLOT_TAKEN'},'occupied slot remains a failure after identity authentication');
equal(await attempts(phone),beforeCollision+1,'slot failure cannot roll back the identity reservation');
for(const hour of [12,14,16,18]) check((await call('spa_create_booking',bookingArgs(phone,'Synthetic identity member',hour))).reference,'five bookings within the daily limit are accepted');
equal(await call('spa_create_booking',bookingArgs(phone,'Synthetic identity member',20)),rateError,'the existing five-bookings-per-24-hours limit is preserved');
for(let index=0;index<5;index++) await call('spa_member_login',[phone,'Wrong name']);
const beforeReplay=await attempts(phone);
await db.query('update spa_services set online_booking_enabled=false where id=$1',[service]);
equal((await call('spa_create_booking',firstArgs)).manage_token,receipt.manage_token,'exact receipt retry works after exhaustion and service unpublication');
equal(await attempts(phone),beforeReplay,'receipt retry never consumes or refreshes attempt allowance');
const changedArgs=[...firstArgs];changedArgs[8]='Changed payload';
await denied(()=>call('spa_create_booking',changedArgs),/REQUEST_CONFLICT/,'same request cannot return a receipt for a changed payload');
await db.query('update spa_services set online_booking_enabled=true where id=$1',[service]);
const fresh=await call('spa_create_booking',bookingArgs('0911990077','Synthetic first booking',20));
check(fresh.reference,'new customers can still create their first booking without SMS');

// Previously issued tokens and receipt capabilities must stop working when
// the customer is blocked or archived, including the older directly callable RPCs.
const reviewAppointment=(await db.query('select id,review_token from spa_appointments where manage_token=$1',[receipt.manage_token])).rows[0];
await db.query("update spa_appointments set status='completed' where id=$1",[reviewAppointment.id]);
const cancellable=(await db.query("select id,manage_token,status from spa_appointments where customer_id=$1 and id<>$2 order by starts_at limit 1",[customer,reviewAppointment.id])).rows[0];
check((await call('spa_manage_booking',[receipt.manage_token])).reference===receipt.reference,'active legacy management link still reads its booking');
check((await call('spa_review_context',[reviewAppointment.review_token])).reference===receipt.reference,'active legacy review link still reads its context');
for(const mode of ['blocked','archived']) {
 await db.query("update spa_customers set status=$2,archived_at=case when $3 then now() else null end where id=$1",[customer,mode==='blocked'?'blocked':'active',mode==='archived']);
 equal(await call('spa_create_booking',firstArgs),identityError,'exact receipt replay cannot disclose a token after customer revocation');
 equal(await attempts(phone),beforeReplay,'revoked receipt retries do not consume or refresh the identity budget');
 equal(await call('spa_manage_booking',[receipt.manage_token]),null,'legacy booking read reveals nothing for a revoked customer');
 equal(await call('spa_booking_link_access',[receipt.manage_token]),null,'private link cannot issue access after customer revocation');
 equal(await call('spa_review_context',[reviewAppointment.review_token]),null,'legacy review context reveals nothing for a revoked customer');
 await denied(()=>call('spa_cancel_booking',[cancellable.manage_token,'Synthetic revocation test']),/NOT_FOUND/,'legacy cancellation cannot mutate a revoked customer booking');
 await denied(()=>call('spa_submit_review',[reviewAppointment.review_token,5,'Synthetic revocation test']),/REVIEW_NOT_ELIGIBLE/,'legacy review cannot issue coupons after customer revocation');
 await denied(()=>call('spa_member_detail',[member.access_token]),/BOOKING_ACCESS_EXPIRED/,'previous member access obeys customer revocation');
}
equal((await db.query('select status from spa_appointments where id=$1',[cancellable.id])).rows[0].status,cancellable.status,'denied cancellations preserve the appointment');
equal(Number((await db.query('select count(*) count from spa_reviews where appointment_id=$1',[reviewAppointment.id])).rows[0].count),0,'denied reviews write no review');
equal(Number((await db.query('select count(*) count from spa_coupons where appointment_id=$1',[reviewAppointment.id])).rows[0].count),0,'denied reviews issue no coupon');
await db.query("update spa_customers set status='active',archived_at=null where id=$1",[customer]);
equal((await call('spa_create_booking',firstArgs)).manage_token,receipt.manage_token,'restoring the customer restores exact receipt retry without duplicating the booking');
await call('spa_submit_review',[reviewAppointment.review_token,5,'Synthetic restored review']);
await call('spa_submit_review',[reviewAppointment.review_token,5,'Synthetic restored review']);
equal(Number((await db.query('select count(*) count from spa_reviews where appointment_id=$1',[reviewAppointment.id])).rows[0].count),1,'restored review link retains idempotent review submission');
equal(Number((await db.query('select count(*) count from spa_coupons where appointment_id=$1',[reviewAppointment.id])).rows[0].count),1,'restored review issues one coupon only');
await call('spa_cancel_booking',[cancellable.manage_token,'Synthetic restored cancellation']);
equal((await db.query('select status from spa_appointments where id=$1',[cancellable.id])).rows[0].status,'cancelled','restored cancellation link preserves the original valid cancellation flow');

await db.query("update spa_products set name=name||' audit' where id=$1",[legacyProduct]);
await db.query("update spa_products set image_url=image_url where id=$1",[legacyProduct]);
equal((await db.query('select image_url from spa_products where id=$1',[legacyProduct])).rows[0].image_url,'http://legacy.example.test/photo.jpg','unmodified legacy HTTP association remains editable');
for(const url of ['http://unsafe.example.test/photo.jpg','https://user:password@example.test/photo.jpg','javascript:alert(1)','//example.test/photo.jpg','https://example.test\\@other.test/photo.jpg']) {
 await denied(()=>db.query('update spa_products set image_url=$2 where id=$1',[legacyProduct,url]),/INVALID_PRODUCT_IMAGE_URL/,'new unsafe product image association is rejected');
}
await db.query("update spa_products set image_url='https://images.example.test/photo.jpg?size=2' where id=$1",[legacyProduct]);
await db.query("update spa_products set image_url='' where id=$1",[legacyProduct]);
await denied(()=>db.query("insert into spa_products(sku,name,price_cents,image_url) values('UNSAFE-IMAGE-TEST','Synthetic unsafe image',0,'http://unsafe.example.test/image.jpg')"),/INVALID_PRODUCT_IMAGE_URL/,'new inserts cannot inherit the legacy HTTP exception');
await db.close();
console.log(`Public identity security: ${checks} checks passed.`);
