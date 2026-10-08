process.on('uncaughtException',e=>{console.error(e.message);if(e.where)console.error(e.where);process.exit(1);});
import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { nextMonthEnd } from '../src/lib/date-range.js';

const db=new PGlite();let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const reject=async(fn,pattern)=>{await assert.rejects(fn,pattern);checks++;};
await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).filter(file=>file.endsWith('.sql')).sort())await db.exec(await readFile(new URL(file,directory),'utf8'));
const owner=randomUUID(),employee=randomUUID(),freshUser=randomUUID();
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)',[owner,'owner@audit.test',employee,'employee@audit.test',freshUser,'custom@audit.test']);
const people=(await db.query("select * from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',null,null),($2,'therapist',$3,'audit_staff')",[owner,employee,people[0].id]);
async function call(user,name,args=[],iat=Math.floor(Date.now()/1000)+10,role=user?'authenticated':'anon'){
 await db.exec('begin');try{await db.exec(`set local role ${role}`);await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat})]);const result=(await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;await db.exec('commit');return result;}catch(e){await db.exec('rollback');throw e;}
}
const admin=(name,args=[])=>call(owner,name,args);
check((await call(employee,'spa_dashboard')).revenue_cents==null,'employee dashboard excludes store revenue');
await admin('spa_staff_account_link',[people[0].id,employee,'therapist',true,true,null]);
for(const name of ['spa_dashboard','spa_reviews_admin','spa_staff_self'])await reject(()=>call(employee,name,name==='spa_staff_self'?['2026-01-01','2026-01-31']:[],Math.floor(Date.now()/1000)-60),/FORBIDDEN/);
check((await call(employee,'spa_session',[],Math.floor(Date.now()/1000)-60)).role===null,'reset password revokes old session identity');
await admin('spa_role_profile_save',['audit_assistant','營運助理',['dashboard.view','appointments.view','reviews.view'],true,50]);
await admin('spa_staff_account_link',[people[1].id,freshUser,'audit_assistant',true,false,'audit_custom']);
check((await call(freshUser,'spa_session')).role==='audit_assistant','owner-created custom role can be assigned to a staff account');
await reject(()=>call(freshUser,'spa_payroll_admin',['2026-01-01','2026-01-31',null]),/FORBIDDEN/);
await admin('spa_role_profile_save',['audit_assistant','營運助理',[],false,50]);
check((await call(freshUser,'spa_session')).role===null,'disabled role profile revokes existing session');
await reject(()=>call(freshUser,'spa_dashboard'),/FORBIDDEN/);
check(await call(null,'spa_staff_login_lookup',['audit_custom'],0,'service_role')===null,'disabled role cannot resolve a username login');
await admin('spa_role_profile_save',['audit_assistant','營運助理',[],true,50]);
check((await call(freshUser,'spa_session')).role==='audit_assistant','role reactivation restores its configured view boundary');
await db.query("update spa_staff set active=false where id=$1",[people[1].id]);
await reject(()=>call(freshUser,'spa_reviews_admin'),/FORBIDDEN/);
await db.query("update spa_staff set active=true where id=$1",[people[1].id]);
check((await admin('spa_session')).role==='owner','owner remains unchanged');

const service=(await db.query("select * from spa_services where active and online_booking_enabled order by display_order limit 1")).rows[0];
const product=(await db.query("select * from spa_products where status='active' order by display_order limit 1")).rows[0];
const room=(await db.query('select id from spa_rooms where active limit 1')).rows[0].id;
const customer=(await db.query("insert into spa_customers(name,phone,customer_type,status) values('核對會員','0991000001','member','active') returning id")).rows[0].id;
const other=(await db.query("insert into spa_customers(name,phone,customer_type,status) values('另一會員','0991000002','member','active') returning id")).rows[0].id;
async function appointment(client,day){return (await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents)
 values($1,$2,$3,$4,$5,(now() at time zone 'Asia/Taipei')::date-$6::int,
 ((now() at time zone 'Asia/Taipei')::date-$6::int+time '10:00') at time zone 'Asia/Taipei',
 ((now() at time zone 'Asia/Taipei')::date-$6::int+time '10:45') at time zone 'Asia/Taipei',
 ((now() at time zone 'Asia/Taipei')::date-$6::int+time '11:00') at time zone 'Asia/Taipei','completed',$7,$8) returning *`,[randomUUID(),client,people[0].id,room,service.id,day,service.name,service.price_cents])).rows[0];}
const source=await appointment(customer,3),target=await appointment(customer,2),wrongTarget=await appointment(other,1);
await call(null,'spa_submit_review',[source.review_token,5,'舒服的服務']);
const reward=(await db.query('select * from spa_coupons where appointment_id=$1',[source.id])).rows[0];
const member=await call(null,'spa_member_login',['0991000001','核對會員']);
check(member.member.coupons.length===1&&member.member.coupons[0].status==='active','review reward is visible to its member');
const privateLink=await call(null,'spa_booking_link_access',[source.manage_token]);
await reject(()=>call(null,'spa_member_detail',[privateLink.access_token]),/FORBIDDEN/);
check((await call(null,'spa_customer_booking_list',[privateLink.access_token])).length===1,'private booking token remains scoped to its single appointment');
await reject(()=>call(employee,'spa_customer_coupons_admin',[customer]),/FORBIDDEN/);
await reject(()=>admin('spa_checkout_with_coupon',[randomUUID(),wrongTarget.id,0,0,null,0,'cash',reward.id]),/COUPON_UNAVAILABLE/);
await reject(()=>admin('spa_checkout_with_coupon',[randomUUID(),target.id,0,0,randomUUID(),0,'cash',reward.id]),/COUPON_WITH_PACKAGE/);
const request=randomUUID(),args=[request,target.id,1000,0,null,0,'cash',reward.id];
const sale=await admin('spa_checkout_with_coupon',args);
check(Number(sale.discount_cents)===6000&&Number(sale.revenue_cents)===Number(service.price_cents)-6000,'coupon and manual discount share the checkout net amount');
check((await call(null,'spa_member_detail',[member.access_token])).coupons[0].status==='redeemed','member sees the successful redemption');
check((await admin('spa_checkout_with_coupon',args)).id===sale.id,'exact checkout retry returns the same sale');
await reject(()=>admin('spa_checkout_with_coupon',[request,target.id,2000,0,null,0,'cash',reward.id]),/REQUEST_CONFLICT/);
check((await db.query('select count(*) n from spa_checkouts where appointment_id=$1',[target.id])).rows[0].n===1,'retry never duplicates checkout');
await admin('spa_refund',[randomUUID(),target.id,'測試退款']);
const restored=(await db.query('select * from spa_coupons where id=$1',[reward.id])).rows[0];
check(restored.status==='active'&&restored.redeemed_at===null&&restored.checkout_id===null,'refund restores coupon availability');
check(new Date(restored.expires_at).valueOf()===new Date(reward.expires_at).valueOf(),'refund preserves coupon original expiry');
const items=[{item_type:'product',item_id:product.id,quantity:1,staff_id:people[0].id}],posRequest=randomUUID();
const posArgs=[posRequest,customer,items,0,'cash','核對',reward.id,Number(product.price_cents)-5000];
const pos=await admin('spa_pos_checkout_with_coupon',posArgs);
check(Number(pos.total_cents)===Number(product.price_cents)-5000,'POS coupon reduces actual collected revenue');
check((await admin('spa_pos_checkout_with_coupon',posArgs)).id===pos.id,'POS retry returns its original sale');
await reject(()=>admin('spa_pos_checkout_with_coupon',[randomUUID(),customer,items,0,'cash','',reward.id,null]),/COUPON_UNAVAILABLE/);
await reject(()=>admin('spa_pos_checkout_with_coupon',[posRequest,customer,items,100,'cash','核對',reward.id,null]),/REQUEST_CONFLICT/);
const inventoryBefore=(await db.query('select sum(delta) n from spa_inventory_entries where product_id=$1',[product.id])).rows[0].n;
await reject(()=>admin('spa_pos_checkout_with_coupon',[randomUUID(),customer,items,0,'cash','',null,1]),/PRICE_CHANGED/);
check((await db.query('select sum(delta) n from spa_inventory_entries where product_id=$1',[product.id])).rows[0].n===inventoryBefore,'changed catalog price rolls back inventory and payment together');
await db.query("update spa_coupons set status='active',redeemed_at=null,order_id=null,expires_at=now()-interval '1 second',issued_at=now()-interval '1 day' where id=$1",[reward.id]);
check(!(await admin('spa_customer_coupons_admin',[customer])).length,'expired coupons are excluded from cashier choices');
await reject(()=>admin('spa_pos_checkout_with_coupon',[randomUUID(),customer,items,0,'cash','',reward.id,null]),/COUPON_UNAVAILABLE/);
await admin('spa_customer_delete',[customer,'DELETE']);
await reject(()=>call(null,'spa_member_detail',[member.access_token]),/BOOKING_ACCESS_EXPIRED/);
check(await call(null,'spa_booking_link_access',[source.manage_token])===null,'archived customer private link no longer grants fresh access');
check(nextMonthEnd('2026-12-31')==='2027-01-31'&&nextMonthEnd('2028-01-01')==='2028-02-29','rescheduling shares the next-month limit including year boundaries and leap days');
await db.close();console.log(`Role, member and coupon consistency checks passed: ${checks}`);
