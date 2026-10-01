process.on('uncaughtException',e=>{console.error(e.message);if(e.where)console.error(e.where);process.exit(1);});
import {PGlite} from '@electric-sql/pglite';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const db=new PGlite();let assertions=0;
const check=(ok,label)=>{assert.ok(ok,label);assertions++;};
const rejected=async(fn,pattern=/FORBIDDEN/)=>{await assert.rejects(fn,pattern);assertions++;};
await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
for(const file of ['202610010001_spa_operations.sql','202610010002_legacy_import.sql','202610010003_customer_booking.sql','202610010004_staff_portal.sql'])await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../supabase/migrations/202610010004_staff_portal.sql',import.meta.url),'utf8'));
const owner=randomUUID(),employee=randomUUID(),manager=randomUUID(),reception=randomUUID(),member=randomUUID(),outsider=randomUUID();
const staff=(await db.query('select * from spa_staff order by display_order')).rows;
const [first,second,third]=staff;
await db.query('insert into auth.users(id,email) select unnest($1::uuid[]),unnest($2::text[])',[[owner,employee,manager,reception,member,outsider],['owner@example.test','therapist@example.test','manager@example.test','desk@example.test','member@example.test','outsider@example.test']]);
await db.query("insert into spa_roles(user_id,role,staff_id) values($1,'owner',null),($2,'therapist',$5),($3,'manager',$6),($4,'receptionist',$7)",[owner,employee,manager,reception,first.id,second.id,third.id]);
async function call(user,name,args=[],iat=Math.floor(Date.now()/1000)){
 await db.exec('begin');
 try{
  await db.exec(`set local role ${user?'authenticated':'anon'}`);
  await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat})]);
  const result=(await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
  await db.exec('commit');return result;
 }catch(e){await db.exec('rollback');throw e;}
}
const admin=(name,args=[])=>call(owner,name,args),anon=(name,args=[])=>call(null,name,args);
const catalog=await anon('spa_catalog');
check(catalog.staff.length===6,'preserve all six people');check(catalog.staff.every(s=>!('base_pay_cents' in s)),'salary not in anonymous catalog');
const [{today,booking_day:day}]=(await db.query("select ((now() at time zone 'Asia/Taipei')::date)::text today,((now() at time zone 'Asia/Taipei')::date+2)::text as booking_day")).rows;
const service=catalog.services[0].id;
const booking=await anon('spa_create_booking',[randomUUID(),service,day,`${day}T10:00:00+08:00`,first.id,'測試會員','0999999901',0,'internal appointment note']);
const a=(await db.query('select * from spa_appointments where manage_token=$1',[booking.manage_token])).rows[0];
await db.query("update spa_customers set notes='private medical preference',auth_user_id=$1 where id=$2",[member,a.customer_id]);
await admin('spa_topup',[randomUUID(),a.customer_id,300000,'cash','owner-only payment note']);
await admin('spa_package_sell',[randomUUID(),a.customer_id,service,'三堂測試套票',3,250000,`${day}T23:59:00+08:00`,'cash']);
const sensitive=['manage_token','review_token','note','checkout','price_cents','tea_cents'];
const forbiddenOperations=[['spa_team_admin',[]],['spa_report',[today,day]],['spa_reviews_admin',[]],['spa_customer_detail',[a.customer_id]],
 ['spa_set_status',[a.id,'confirmed','']],['spa_reschedule',[a.id,day,`${day}T11:00:00+08:00`,first.id,'test']],
 ['spa_customer_save',[a.customer_id,'changed','0999999901','','一般會員','',null]],['spa_topup',[randomUUID(),a.customer_id,100,'cash','test']],
 ['spa_wallet_adjust',[randomUUID(),a.customer_id,100,'test']],['spa_package_sell',[randomUUID(),a.customer_id,service,'x',1,100,`${day}T23:59:00+08:00`,'cash']],
 ['spa_checkout',[randomUUID(),a.id,0,0,null,0,'cash']],['spa_refund',[randomUUID(),a.id,'test']],['spa_expense',[randomUUID(),100,'cash','test']],
 ['spa_staff_save',[first.id,'changed','','','','',0,true,[service]]],['spa_shift_save',[first.id,1,600,1560]],
 ['spa_time_off_save',[first.id,`${day}T12:00:00+08:00`,`${day}T13:00:00+08:00`,'test']],['spa_time_off_delete',[randomUUID()]],
 ['spa_settings_save',[600,1560,30,false,24]],['spa_staff_archive',[first.id,true,'test']],['spa_staff_account_target',[first.id]],
 ['spa_staff_account_link',[first.id,employee,'therapist',true,false]],['spa_role_save',[employee,'owner',first.id,true]]];
for(const user of [employee,manager,reception]){
 const schedule=await call(user,'spa_admin_bookings',[today,day]);check(schedule.some(b=>b.id===a.id),'employee can read schedule');
 check(sensitive.every(k=>!(k in schedule[0])),'schedule strips tokens and financial/internal fields');
 const customers=await call(user,'spa_customers_list');check(customers[0].balance_cents===300000,'employee reads credits');
 check(!('notes' in customers[0])&&!('auth_user_id' in customers[0])&&!('email' in customers[0]),'employee sees necessary member fields only');
 const detail=await call(user,'spa_employee_customer',[a.customer_id]);check(detail.packages[0].remaining===3&&!('paid_cents' in detail.packages[0]),'employee reads package balance without payment data');
 for(const [name,args] of forbiddenOperations)await rejected(()=>call(user,name,args));
}
await rejected(()=>call(outsider,'spa_customers_list'));await rejected(()=>anon('spa_customers_list'),/permission denied|FORBIDDEN/);
await rejected(()=>admin('spa_role_save',[owner,'therapist',first.id,true]),/OWNER_PROTECTED/);
await rejected(()=>admin('spa_staff_account_link',[first.id,owner,'therapist',true,false]),/OWNER_PROTECTED/);
check((await admin('spa_session')).role==='owner','owner preserved');
const saved=await admin('spa_staff_profile_save',[first.id,first.name,first.name_en,'資深技師',first.specialty,first.bio,1200,true,catalog.services.map(s=>s.id),'monthly',4500000]);
check(saved===first.id,'existing staff ID preserved');
let self=await call(employee,'spa_staff_self',[today,day]);check(self.profile.base_pay_cents===4500000&&self.profile.commission_bps===1200,'only own compensation available');
const other=await call(manager,'spa_staff_self',[today,day]);check(other.profile.id===second.id&&other.profile.base_pay_cents===null,'other employee cannot see first salary');
await rejected(()=>call(employee,'spa_staff_self',[day,today]),/INVALID_DATE/);
await rejected(()=>admin('spa_staff_archive',[first.id,true,'departure']),/EXISTING_BOOKINGS/);
await rejected(()=>admin('spa_staff_account_link',[second.id,employee,'manager',true,false]),/ACCOUNT_CONFLICT/);
const lookup=await anon('spa_lookup_bookings',['0999999901','測試會員']);
check(!lookup.appointments[0].can_review&&!lookup.appointments[0].review_submitted,'future visit cannot be reviewed');
await rejected(()=>anon('spa_customer_review',[lookup.access_token,a.id,5,'test']),/REVIEW_NOT_ELIGIBLE/);
await db.query("update spa_appointments set starts_at=now()-interval '2 hours',ends_at=now()-interval '75 minutes',blocked_until=now()-interval '1 hour',business_date=$2 where id=$1",[a.id,today]);
check(!(await anon('spa_customer_booking_list',[lookup.access_token]))[0].can_review,'merely expired pending visit cannot be reviewed');
for(const status of ['cancelled','no_show']){
 await db.query('update spa_appointments set status=$2 where id=$1',[a.id,status]);
 await rejected(()=>anon('spa_customer_review',[lookup.access_token,a.id,5,'test']),/REVIEW_NOT_ELIGIBLE/);
}
await db.query("update spa_appointments set status='completed' where id=$1",[a.id]);
const cancelled=(await anon('spa_customer_booking_list',[lookup.access_token]))[0];check(cancelled.can_review,'confirmed completed visit can be reviewed');
const otherBooking=await anon('spa_create_booking',[randomUUID(),service,day,`${day}T12:00:00+08:00`,second.id,'另一位顧客','0999999902',0,'']);
const a2=(await db.query('select * from spa_appointments where manage_token=$1',[otherBooking.manage_token])).rows[0];
await rejected(()=>anon('spa_customer_review',[lookup.access_token,a2.id,5,'wrong customer']),/NOT_FOUND/);
await rejected(()=>anon('spa_customer_review',[randomUUID(),a.id,5,'invalid access']),/BOOKING_ACCESS_EXPIRED/);
await rejected(()=>anon('spa_customer_review',[lookup.access_token,a.id,6,'test']),/INVALID_INPUT/);
const reviewed=await anon('spa_customer_review',[lookup.access_token,a.id,5,'細心、舒適的療程']);
check(reviewed.review_submitted&&!reviewed.can_review,'one review recorded and marked submitted');
await anon('spa_customer_review',[lookup.access_token,a.id,1,'duplicate']);
check((await db.query('select rating,comment from spa_reviews where appointment_id=$1',[a.id])).rows[0].rating===5,'duplicate cannot overwrite first review');
check(!(await anon('spa_public_reviews')).length,'review awaits owner moderation');
await admin('spa_checkout',[randomUUID(),a.id,0,0,null,0,'cash']);
self=await call(employee,'spa_staff_self',[today,day]);check(self.metrics.completed===1&&self.metrics.minutes===45&&self.metrics.reviews===1&&self.metrics.rating===5,'personal classes and reviews match actual visits');
check(self.metrics.commission_cents===13200,'personal commission uses checkout snapshot');
check(self.reviews[0].comment==='細心、舒適的療程'&&!('phone' in self.reviews[0])&&!('customer_name' in self.reviews[0]),'own reviews omit customer identity');
check(!(await call(manager,'spa_staff_self',[today,day])).reviews.length,'other staff never receive these reviews');
await admin('spa_staff_profile_save',[first.id,first.name,first.name_en,'資深技師',first.specialty,first.bio,2500,true,[service],'monthly',4600000]);
check((await call(employee,'spa_staff_self',[today,day])).metrics.commission_cents===13200,'new rate does not rewrite old commission');
const memberDetail=await call(member,'spa_customer_detail',[a.customer_id]);check(memberDetail.appointments[0].review_submitted,'member sees submitted review');
await admin('spa_staff_account_link',[first.id,employee,'therapist',false,false]);
await rejected(()=>call(employee,'spa_customers_list'));check((await call(employee,'spa_session')).role===null,'disabled role blocks existing session');
await admin('spa_staff_account_link',[first.id,employee,'therapist',true,true]);
await rejected(()=>call(employee,'spa_customers_list',[],Math.floor(Date.now()/1000)-60));
check((await call(employee,'spa_session',[],Math.floor(Date.now()/1000)+10)).role==='therapist','new password session is allowed');
await admin('spa_staff_archive',[first.id,true,'離職']);
await rejected(()=>call(employee,'spa_staff_self',[today,day],Math.floor(Date.now()/1000)+10));
check((await db.query('select count(*) n from spa_staff')).rows[0].n===6,'archive preserves personnel record');
check((await db.query('select count(*) n from spa_reviews')).rows[0].n===1,'archive preserves historical review');
await rejected(()=>admin('spa_staff_profile_save',[first.id,first.name,'','','','',0,true,[],'monthly',null]),/STAFF_ARCHIVED/);
await admin('spa_staff_archive',[first.id,false,'復職']);
check((await db.query('select active,archived_at from spa_staff where id=$1',[first.id])).rows[0].active===false,'restoring person does not automatically resume booking');
await admin('spa_staff_account_link',[first.id,employee,'therapist',true,false]);
const ownerTeam=await admin('spa_team_admin');check(ownerTeam.roles.some(r=>r.user_id===employee&&!r.email),'employee account emails are not returned in team data');
await rejected(()=>call(employee,'spa_customers_list',[],Math.floor(Date.now()/1000)-60));
// Test fixture contains synthetic identities only and never leaves this local repository.
await mkdir('work',{recursive:true});await writeFile('work/staff-qa.json',JSON.stringify({catalog,ownerTeam,ownerSchedule:await admin('spa_admin_bookings',[today,day]),employeeSchedule:await call(employee,'spa_admin_bookings',[today,day],Math.floor(Date.now()/1000)+10),customers:await call(employee,'spa_customers_list',[],Math.floor(Date.now()/1000)+10),self:await call(employee,'spa_staff_self',[today,day],Math.floor(Date.now()/1000)+10),memberDetail,lookup:await anon('spa_customer_booking_list',[lookup.access_token]),customerDetail:await call(employee,'spa_employee_customer',[a.customer_id],Math.floor(Date.now()/1000)+10),owner,employee,today,day,access:lookup.access_token}));
await admin('spa_staff_account_link',[first.id,employee,'therapist',true,false,'rou_staff']);
check((await admin('spa_staff_account_target',[first.id])).account.username==='rou_staff','owner assigns username without employee email');
await rejected(()=>admin('spa_staff_account_link',[second.id,manager,'manager',true,false,'ROU_STAFF']),/USERNAME_TAKEN/);
await rejected(()=>call(employee,'spa_staff_login_lookup',['rou_staff']),/permission denied/);
await db.exec('set role service_role');
let target=(await db.query("select spa_staff_login_lookup('ROU_STAFF') result")).rows[0].result;
check(target.user_id===employee&&target.email==='therapist@example.test','server resolves normalized username to Auth identity');
for(let i=0;i<20;i++)target=(await db.query("select spa_staff_login_lookup('rou_staff') result")).rows[0].result;
check(target.limited===true,'login attempts capped per username');
await db.exec('reset role');
await db.close();console.log(`PASS: ${assertions} staff permission, compensation and review assertions`);
