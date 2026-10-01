process.on('uncaughtException', e=>{console.error(e.stack);if(e.where)console.error(e.where);process.exit(1);});
import { PGlite } from '@electric-sql/pglite';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const db = new PGlite();
let assertions=0;
const check=(value,message)=>{assert.ok(value,message);assertions++;};
await db.exec(`create role anon; create role authenticated; create role service_role;
create schema auth; create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth to anon,authenticated; grant execute on function auth.uid() to anon,authenticated;`);
await db.exec(await readFile(new URL('../supabase/migrations/202610010001_spa_operations.sql',import.meta.url),'utf8'));
async function as(role,user,sql,params=[]){
 await db.exec('begin');
 try{
  await db.exec(`set local role ${role}`);
  await db.query("select set_config('request.jwt.claim.sub',$1,true)",[user||'']);
  const result=await db.query(sql,params);await db.exec('commit');return result.rows;
 }catch(e){await db.exec('rollback');throw e;}
}
const owner=randomUUID(),reception=randomUUID(),therapist=randomUUID(),member=randomUUID(),outsider=randomUUID();
await db.query('insert into auth.users(id) select unnest($1::uuid[])',[[owner,reception,therapist,member,outsider]]);
const [{id:staff}]= (await db.query('select id from spa_staff order by display_order')).rows;
await db.query("insert into spa_roles(user_id,role,staff_id) values($1,'owner',null),($2,'receptionist',null),($3,'therapist',$4)",[owner,reception,therapist,staff]);
const call=async(role,user,name,args=[])=>{
 const ps=args.map((_,i)=>`$${i+1}`).join(',');if(name==='spa_availability')return as(role,user,`select * from public.${name}(${ps})`,args);return (await as(role,user,`select public.${name}(${ps}) result`,args))[0]?.result;
};
const admin=(name,args)=>call('authenticated',owner,name,args);
const anon=(name,args)=>call('anon',null,name,args);
async function rejected(fn,pattern){await assert.rejects(fn,pattern);assertions++;}
const cat=await anon('spa_catalog');check(cat.staff.length===6,'all 6 therapists');
check((await db.query('select count(*) n from spa_rooms')).rows[0].n===4,'four beds');
const service=cat.services[0].id,service90=cat.services[1].id;
const [{booking_day:day,today}]=(await db.query("select ((now() at time zone 'Asia/Taipei')::date+2)::text as booking_day,(now() at time zone 'Asia/Taipei')::date::text today")).rows;
const start=`${day}T10:00:00+08:00`;
const booking=(req,phone,at=start,who=null,svc=service)=>anon('spa_create_booking',[req,svc,day,at,who,'測試會員',phone,0,'測試備註']);
const request=randomUUID(),first=await booking(request,'0911111111');
check(first.status==='pending','pending default');
const duplicate=await booking(request,'0911111111');check(duplicate.manage_token===first.manage_token,'idempotent booking');
await rejected(()=>booking(request,'0911111112'),/REQUEST_CONFLICT/);
const a=(await db.query('select * from spa_appointments where request_id=$1',[request])).rows[0];
// Regression: successful public booking is hidden by a today-only filter, visible in seven days.
const todayOnly=await admin('spa_admin_bookings',[today,today]);
check(!todayOnly.some(row=>row.reference===first.reference),'today-only filter excludes future public booking');
const [{week_end:weekEnd}]=(await db.query("select ((now() at time zone 'Asia/Taipei')::date+6)::text week_end")).rows;
const weekBookings=await admin('spa_admin_bookings',[today,weekEnd]);
check(weekBookings.some(row=>row.reference===first.reference),'seven-day admin range includes future public booking');
const publicDetail=await anon('spa_manage_booking',[first.manage_token]);
check(publicDetail.reference===first.reference,'public receipt and admin read same stored appointment');

await rejected(()=>booking(randomUUID(),'0911111112',`${day}T10:30:00+08:00`,a.staff_id),/SLOT_TAKEN/);
check((await anon('spa_availability',[service,day,a.staff_id])).find(s=>new Date(s.starts_at).getTime()===new Date(`${day}T11:00:00+08:00`).getTime()).available,'buffer boundary permits next booking');
for(const tel of ['0922222222','0933333333','0944444444'])await booking(randomUUID(),tel);
await rejected(()=>booking(randomUUID(),'0955555555'),/SLOT_TAKEN/);
check(!(await anon('spa_availability',[service,day,null])).find(s=>new Date(s.starts_at).getTime()===new Date(start).getTime()).available,'bed capacity unavailable despite 6 staff');
await rejected(()=>as('anon',null,'select * from spa_customers'),/permission denied/);
await rejected(()=>as('authenticated',outsider,'select * from spa_wallet_entries'),/permission denied/);
await rejected(()=>call('authenticated',outsider,'spa_customers_list'),/FORBIDDEN/);
await rejected(()=>call('authenticated',reception,'spa_report',[today,today]),/FORBIDDEN/);
await rejected(()=>call('authenticated',therapist,'spa_customers_list'),/FORBIDDEN/);
const own=await call('authenticated',therapist,'spa_admin_bookings',[day,day]);check(own.every(b=>b.staff_id===staff),'therapist own calendar only');
await rejected(()=>call('authenticated',reception,'spa_role_save',[outsider,'owner',null,true]),/FORBIDDEN/);
await rejected(()=>admin('spa_role_save',[owner,'manager',null,true]),/OWNER_SELF_CHANGE/);
await rejected(()=>admin('spa_set_status',[a.id,'completed','']),/INVALID_TRANSITION/);
await admin('spa_set_status',[a.id,'confirmed','']);
await rejected(()=>admin('spa_set_status',[a.id,'checked_in','']),/TOO_EARLY/);
await rejected(()=>admin('spa_time_off_save',[a.staff_id,start,`${day}T12:00:00+08:00`,'休假']),/EXISTING_BOOKINGS/);
// Reschedule failure must restore original allocation and status.
const blockingStaff=(await db.query('select staff_id from spa_appointments where id<>$1 limit 1',[a.id])).rows[0].staff_id;
await rejected(()=>admin('spa_reschedule',[a.id,day,`${day}T10:30:00+08:00`,blockingStaff,'改期']),/SLOT_TAKEN/);
check((await db.query('select status from spa_appointments where id=$1',[a.id])).rows[0].status==='confirmed','failed reschedule rollback');
const offStaff=cat.staff.find(s=>s.id!==a.staff_id&& ![...own].some(b=>b.staff_id===s.id))?.id;
// Overnight slots keep their business date and enforce treatment + cleanup before closing.
const midnight=(await anon('spa_availability',[service,day,null])).find(s=>s.time_label==='翌日 00:30');
check(midnight.available,'overnight availability');
check(!(await anon('spa_availability',[service90,day,null])).find(s=>s.time_label==='翌日 01:00').available,'treatment exceeds closing');
const night=await booking(randomUUID(),'0966666666',midnight.starts_at);check(!!night.reference,'overnight booking');
// Backdate the first appointment as a test fixture, then exercise actual workflow.
await db.query("update spa_appointments set starts_at=now()-interval '2 hours',ends_at=now()-interval '75 minutes',blocked_until=now()-interval '1 hour',business_date=$2 where id=$1",[a.id,today]);
await admin('spa_set_status',[a.id,'checked_in','']);await admin('spa_set_status',[a.id,'completed','']);
await db.query('update spa_customers set auth_user_id=$2 where id=$1',[a.customer_id,member]);
const topup=randomUUID();await admin('spa_topup',[topup,a.customer_id,200000,'cash','充值']);await admin('spa_topup',[topup,a.customer_id,200000,'cash','充值']);
check((await db.query('select sum(amount_cents) n from spa_wallet_entries where customer_id=$1',[a.customer_id])).rows[0].n==200000,'topup exactly once');
const report=await admin('spa_report',[today,today]);check(report.revenue_cents===0&&report.cash_in_cents===200000,'topup cash excludes earned revenue');
await rejected(()=>admin('spa_checkout',[randomUUID(),a.id,0,300000,null,0,'cash']),/INSUFFICIENT_CREDITS/);
check((await db.query('select count(*) n from spa_checkouts')).rows[0].n===0,'failed checkout writes nothing');
const checkoutRequest=randomUUID();const checkout=await admin('spa_checkout',[checkoutRequest,a.id,0,110000,null,5000,'cash']);
await admin('spa_checkout',[checkoutRequest,a.id,0,110000,null,5000,'cash']);
check(checkout.wallet_cents===110000&&checkout.cash_cents===0,'wallet redemption exact');
await rejected(()=>admin('spa_checkout',[randomUUID(),a.id,0,0,null,0,'cash']),/INVALID_TRANSITION/);
let detail=await call('authenticated',member,'spa_customer_detail',[a.customer_id]);check(detail.wallet.reduce((n,w)=>n+w.amount_cents,0)===90000,'member balance');
await rejected(()=>call('authenticated',outsider,'spa_customer_detail',[a.customer_id]),/FORBIDDEN/);
await rejected(()=>admin('spa_wallet_adjust',[randomUUID(),a.customer_id,-100000,'測試']),/INSUFFICIENT_CREDITS/);
await anon('spa_submit_review',[a.review_token,4,'很好']);await anon('spa_submit_review',[a.review_token,5,'第二次']);
check((await db.query('select count(*) n from spa_reviews')).rows[0].n===1,'one review per completed appointment');
check((await anon('spa_public_reviews')).length===0,'pending reviews private');
const review=(await db.query('select id from spa_reviews')).rows[0];await admin('spa_moderate',['review',review.id,'published','謝謝']);
const publicReviews=await anon('spa_public_reviews');check(publicReviews.length===1&&!JSON.stringify(publicReviews).includes('0911111111'),'published reviews exclude PII');
const refund=randomUUID();await admin('spa_refund',[refund,a.id,'退款測試']);await admin('spa_refund',[refund,a.id,'退款測試']);
detail=await call('authenticated',member,'spa_customer_detail',[a.customer_id]);check(detail.wallet.reduce((n,w)=>n+w.amount_cents,0)===200000,'refund restores wallet once');
const refunded=await admin('spa_report',[today,today]);check(refunded.revenue_cents===0,'refund reverses earned revenue');check(refunded.cash_out_cents===5000,'tip refund recorded separately from wallet');
// Package monetary recognition and session restore.
await admin('spa_package_sell',[randomUUID(),a.customer_id,service,'三次套票',3,300001,`${day}T23:59:00+08:00`,'cash']);
const pkg=(await db.query('select * from spa_packages')).rows[0];
const future=await booking(randomUUID(),'0911111111',`${day}T14:00:00+08:00`);
const a2=(await db.query('select * from spa_appointments where manage_token=$1',[future.manage_token])).rows[0];
await db.query("update spa_appointments set starts_at=now()-interval '4 hours',ends_at=now()-interval '195 minutes',blocked_until=now()-interval '3 hours',business_date=$2,status='completed' where id=$1",[a2.id,today]);
const ch2=await admin('spa_checkout',[randomUUID(),a2.id,0,0,pkg.id,0,'cash']);check(ch2.revenue_cents===100000&&ch2.cash_cents===0,'package revenue recognized per session without double cash');
detail=await call('authenticated',member,'spa_customer_detail',[a.customer_id]);check(detail.packages[0].remaining===2,'one package session deducted');
await admin('spa_refund',[randomUUID(),a2.id,'退還療程']);detail=await call('authenticated',member,'spa_customer_detail',[a.customer_id]);check(detail.packages[0].remaining===3,'package refund restores session');
// Exhaust a non-divisible package, refund the first redemption, then consume again.
await db.query("update spa_appointments set created_at=now()-interval '2 days' where customer_id=$1",[a.customer_id]);
const redeemed=[];
for(let i=0;i<3;i++){
 const result=await booking(randomUUID(),'0911111111',`${day}T${16+i}:00:00+08:00`);
 const ap=(await db.query('select * from spa_appointments where manage_token=$1',[result.manage_token])).rows[0];
 await db.query("update spa_appointments set starts_at=now()-interval '12 hours'+$3*interval '2 hours',ends_at=now()-interval '11 hours'+$3*interval '2 hours',blocked_until=now()-interval '11 hours'+$3*interval '2 hours',business_date=$2,status='completed' where id=$1",[ap.id,today,i]);
 const ch=await admin('spa_checkout',[randomUUID(),ap.id,0,0,pkg.id,0,'cash']);redeemed.push({ap,ch});
}
check(redeemed.reduce((n,r)=>n+r.ch.revenue_cents,0)===300001,'all package rounding recognized exactly');
await admin('spa_refund',[randomUUID(),redeemed[0].ap.id,'還原第一個療程']);
const again=await booking(randomUUID(),'0911111111',`${day}T20:00:00+08:00`);
const ap3=(await db.query('select * from spa_appointments where manage_token=$1',[again.manage_token])).rows[0];
await db.query("update spa_appointments set starts_at=now()-interval '20 hours',ends_at=now()-interval '19 hours',blocked_until=now()-interval '19 hours',business_date=$2,status='completed' where id=$1",[ap3.id,today]);
const recheckout=await admin('spa_checkout',[randomUUID(),ap3.id,0,0,pkg.id,0,'cash']);
check(recheckout.revenue_cents===redeemed[0].ch.revenue_cents,'refund then last redemption does not duplicate rounding');
check((await db.query('select sum(revenue_cents) n from spa_checkouts where package_id=$1 and refunded_at is null',[pkg.id])).rows[0].n==300001,'net package revenue never exceeds purchase');
await anon('spa_cancel_booking',[night.manage_token,'客人取消']);check((await anon('spa_manage_booking',[night.manage_token])).status==='cancelled','private link cancellation');
await anon('spa_submit_feedback',['服務很好，希望改善飲品']);
await rejected(()=>as('anon',null,'select * from spa_feedback'),/permission denied/);
await db.exec(`create table public.bookings(id bigint,service text,therapist_index int,booking_date text,booking_time text,customer_name text,phone text,tea text,note text,status text,created_at timestamptz);
insert into public.bookings values(1,'全息頭部SPA',0,'2026-01-02','10:00','舊會員','0989898989','','','confirmed','2026-01-01'),(2,'測試',99,'2099-12-31','10:00','测试','0','','','confirmed','2026-01-01');`);
await db.exec(await readFile(new URL('../supabase/migrations/202610010002_legacy_import.sql',import.meta.url),'utf8'));
const legacy=await admin('spa_legacy_report');check(legacy.length===2&&legacy.filter(r=>r.outcome==='needs_review').length===1,'legacy import retains invalid sources for review');
check((await db.query('select count(*) n from public.bookings')).rows[0].n===2,'legacy source untouched');
await rejected(()=>as('anon',null,'select * from spa_legacy_imports'),/permission denied/);
// Customer lookup/mutations: real anonymous permissions and the same appointment rows as admin.
const customerMigration=await readFile(new URL('../supabase/migrations/202610010003_customer_booking.sql',import.meta.url),'utf8');
await db.exec(customerMigration);
await db.exec(customerMigration); // Incremental migration can safely be applied again.
check(Math.abs(Date.parse(await anon('spa_server_time'))-Date.now())<5000,'public authoritative server clock');
const newA=await booking(randomUUID(),'0977000001',`${day}T12:00:00+08:00`);
const newB=await booking(randomUUID(),'0977000001',`${day}T14:00:00+08:00`);
const other=await booking(randomUUID(),'0977000002',`${day}T16:00:00+08:00`);
const wrong=await anon('spa_lookup_bookings',['0977000001','錯誤姓名']);
check(wrong.appointments.length===0&&!wrong.access_token,'phone alone and wrong full name do not grant access');
const lookup=await anon('spa_lookup_bookings',['0977-000-001',' 測試會員 ']);
check(lookup.appointments.length===2&&!!lookup.access_token,'normalized phone plus full name grants customer scope');
check(!JSON.stringify(lookup).includes(newA.manage_token)&&!JSON.stringify(lookup).includes('review_token'),'lookup never exposes permanent tokens');
const ca=lookup.appointments.find(row=>row.reference===newA.reference),cb=lookup.appointments.find(row=>row.reference===newB.reference);
check(ca.can_change&&!!ca.change_before,'change deadline comes from store settings');
const otherId=(await db.query('select id from spa_appointments where manage_token=$1',[other.manage_token])).rows[0].id;
await rejected(()=>anon('spa_customer_cancel',[lookup.access_token,otherId,randomUUID(),'越權']),/NOT_FOUND/);
await rejected(()=>anon('spa_customer_reschedule',[lookup.access_token,otherId,randomUUID(),day,`${day}T18:00:00+08:00`,null,'越權']),/NOT_FOUND/);
for(const table of ['spa_booking_access','spa_booking_lookup_limits','spa_booking_actions'])await rejected(()=>as('anon',null,`select * from public.${table}`),/permission denied/);
const link=await anon('spa_booking_link_access',[newA.manage_token]);
check(link.appointments.length===1,'private receipt link is restricted to one appointment');
await rejected(()=>anon('spa_customer_cancel',[link.access_token,cb.id,randomUUID(),'越權']),/NOT_FOUND/);
check(await anon('spa_booking_link_access',[randomUUID()])===null,'invalid private link returns no appointment');
const available=await as('anon',null,'select * from spa_customer_availability($1,$2,$3,$4)',[lookup.access_token,ca.id,day,ca.staff_id]);
check(available.find(s=>Date.parse(s.starts_at)===Date.parse(ca.starts_at)).available,'own original slot remains available when rescheduling');
await rejected(()=>anon('spa_customer_reschedule',[lookup.access_token,ca.id,randomUUID(),day,cb.starts_at,cb.staff_id,'衝突']),/SLOT_TAKEN/);
check((await anon('spa_customer_booking_list',[lookup.access_token])).find(s=>s.id===ca.id).starts_at===ca.starts_at,'failed reschedule preserves original slot');
await rejected(()=>anon('spa_customer_reschedule',[lookup.access_token,ca.id,randomUUID(),day,`${day}T18:01:00+08:00`,null,'不合法']),/INVALID_DATE/);
await rejected(()=>anon('spa_customer_cancel',[lookup.access_token,ca.id,randomUUID(),' ']),/REASON_REQUIRED/);
// Editing current catalog must not silently change the already booked duration, buffer or price.
await db.query('update spa_services set duration_minutes=120,buffer_minutes=30,price_cents=999999 where id=$1',[service]);
const moveRequest=randomUUID();
const moved=await anon('spa_customer_reschedule',[lookup.access_token,ca.id,moveRequest,day,`${day}T18:00:00+08:00`,ca.staff_id,'客人改期']);
check(moved.id===ca.id&&moved.reference===ca.reference,'reschedule updates same appointment identity');
check(Date.parse(moved.ends_at)-Date.parse(moved.starts_at)===45*60000&&moved.price_cents===ca.price_cents,'reschedule preserves booked duration and price');
const movedRow=(await db.query('select * from spa_appointments where id=$1',[ca.id])).rows[0];
check(Date.parse(movedRow.blocked_until)-Date.parse(movedRow.ends_at)===15*60000,'reschedule preserves booked cleanup buffer');
check((await anon('spa_customer_reschedule',[lookup.access_token,ca.id,moveRequest,day,`${day}T18:00:00+08:00`,ca.staff_id,'客人改期'])).starts_at===moved.starts_at,'reschedule retry is idempotent');
await rejected(()=>anon('spa_customer_reschedule',[lookup.access_token,ca.id,moveRequest,day,`${day}T20:00:00+08:00`,ca.staff_id,'客人改期']),/REQUEST_CONFLICT/);
const synced=await admin('spa_admin_bookings',[day,day]);
check(synced.find(s=>s.id===ca.id).starts_at===moved.starts_at,'public reschedule is visible through actual admin RPC');
check((await db.query("select count(*) n from spa_audit where action='booking.customer_rescheduled' and entity_id=$1",[ca.id])).rows[0].n===1,'reschedule audits exactly once');
const cancelRequest=randomUUID();const cancelled=await anon('spa_customer_cancel',[lookup.access_token,cb.id,cancelRequest,'客人取消']);
check(cancelled.status==='cancelled'&&!cancelled.can_change,'customer cancellation changes status and disables further changes');
await anon('spa_customer_cancel',[lookup.access_token,cb.id,cancelRequest,'客人取消']);
check((await admin('spa_admin_bookings',[day,day])).find(s=>s.id===cb.id).status==='cancelled','public cancel synchronizes to actual admin RPC');
check((await db.query("select count(*) n from spa_audit where action='booking.customer_cancelled' and entity_id=$1",[cb.id])).rows[0].n===1,'cancellation audits exactly once');
await rejected(()=>anon('spa_customer_reschedule',[lookup.access_token,cb.id,randomUUID(),day,`${day}T20:00:00+08:00`,null,'取消後改期']),/INVALID_TRANSITION/);
await db.query("update spa_appointments set starts_at=now()+interval '2 hours',ends_at=now()+interval '165 minutes',blocked_until=now()+interval '3 hours' where id=$1",[ca.id]);
await rejected(()=>anon('spa_customer_cancel',[lookup.access_token,ca.id,randomUUID(),'期限內']),/CANCELLATION_CUTOFF/);
await rejected(()=>anon('spa_customer_reschedule',[lookup.access_token,ca.id,randomUUID(),day,`${day}T20:00:00+08:00`,null,'期限內']),/RESCHEDULE_CUTOFF/);
await db.query("update spa_appointments set starts_at=now()-interval '10 days',ends_at=now()-interval '10 days'+interval '45 minutes',blocked_until=now()-interval '10 days'+interval '1 hour' where id=$1",[ca.id]);
check((await anon('spa_customer_booking_list',[lookup.access_token])).some(s=>s.id===ca.id),'past appointments remain available for Nonactive history');
await db.query("update spa_booking_access set expires_at=now()-interval '1 second' where token=$1",[lookup.access_token]);
await rejected(()=>anon('spa_customer_booking_list',[lookup.access_token]),/BOOKING_ACCESS_EXPIRED/);
await rejected(()=>anon('spa_customer_cancel',[lookup.access_token,cb.id,randomUUID(),'過期權限']),/BOOKING_ACCESS_EXPIRED/);
for(let i=0;i<10;i++)await anon('spa_lookup_bookings',['0977000003','無資料']);
await rejected(()=>anon('spa_lookup_bookings',['0977000003','無資料']),/RATE_LIMIT/);
await db.query("update spa_booking_lookup_limits set window_start=now()-interval '11 minutes' where phone_hash=md5('0977000003')");
check((await anon('spa_lookup_bookings',['0977000003','無資料'])).appointments.length===0,'lookup limit resets after the window');

const priv=(await db.query("select count(*) n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='spa_private' and has_function_privilege('anon',p.oid,'EXECUTE')")).rows[0].n;check(priv===0,'private helpers cannot be called by anon');
check((await db.query("select count(*) n from pg_tables where schemaname='public' and tablename like 'spa_%' and not rowsecurity")).rows[0].n===0,'all app tables RLS enabled');
console.log(`PASS: ${assertions} PostgreSQL assertions (migration, allocation, roles, wallet, packages, checkout, refunds, reviews, overnight time, customer lookup/cancel/reschedule).`);
if(process.env.SPA_UI_FIXTURES){
 const fixtures={owner,day,today,spa_catalog:await anon('spa_catalog'),spa_session:{role:'owner',staff_id:null,customer_id:null},spa_admin_bookings:await admin('spa_admin_bookings',[today,day]),spa_customers_list:await admin('spa_customers_list'),spa_team_admin:await admin('spa_team_admin'),spa_reviews_admin:await admin('spa_reviews_admin'),spa_report:await admin('spa_report',[today,day]),spa_legacy_report:await admin('spa_legacy_report'),spa_customer_detail:await admin('spa_customer_detail',[a.customer_id])};
 await mkdir('work',{recursive:true});await writeFile('work/ui-fixtures.json',JSON.stringify(fixtures));
}
await db.close();
