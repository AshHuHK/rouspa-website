import assert from 'node:assert/strict';
import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';

const db=new PGlite();let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const reject=async(fn,pattern)=>{await assert.rejects(fn,pattern);checks++;};
process.on('uncaughtException',error=>{console.error(error.stack);if(error.where)console.error(error.where);process.exit(1);});
await db.exec(`create role anon;create role authenticated;create role service_role;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).filter(file=>file.endsWith('.sql')).sort()){
 let sql=await readFile(new URL(file,directory),'utf8');
 if(file==='202610070001_staff_schedule_booking_flow.sql')await db.exec(`create table public.consistency_test_clock(at_time timestamptz);
  insert into public.consistency_test_clock values('2026-10-05T10:00:00+08:00');
  create function spa_private.consistency_test_now() returns timestamptz language sql stable as $$select at_time from public.consistency_test_clock$$;`);
 if(file>='202610070001_staff_schedule_booking_flow.sql')sql=sql.replaceAll('now()','spa_private.consistency_test_now()');
 await db.exec(sql);
}
const owner=randomUUID(),employee=randomUUID();
const staff=(await db.query("select id from spa_staff where active and employment_status='active' order by display_order")).rows.map(row=>row.id);
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)',[owner,'owner@consistency.test',employee,'staff@consistency.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name) values($1,'owner',null,true,null),($2,'therapist',$3,true,'consistency_staff')",[owner,employee,staff[0]]);
async function as(user,sql,args=[]){await db.exec('begin');try{await db.exec('set local role '+(user?'authenticated':'anon'));await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat:1800000000})]);const result=await db.query(sql,args);await db.exec('commit');return result.rows;}catch(error){await db.exec('rollback');throw error;}}
const rpc=async(user,name,args=[])=> (await as(user,`select public.${name}(${args.map((_,index)=>'$'+(index+1)).join(',')}) result`,args))[0]?.result;
const rows=(user,name,args=[])=>as(user,`select * from public.${name}(${args.map((_,index)=>'$'+(index+1)).join(',')})`,args);
const service=(await db.query("select id from spa_services where active and status='active' and online_booking_enabled order by display_order limit 1")).rows[0].id;
await db.query('insert into spa_staff_services(staff_id,service_id,enabled) select unnest($1::uuid[]),$2,true on conflict(staff_id,service_id) do update set enabled=true',[staff,service]);
const date='2026-11-12',rosterDate='2026-11-13';
for(const day of [date,rosterDate]){
 await rpc(owner,'spa_business_day_override_save',[day,true,600,1320,'測試營業時間']);
 for(const person of staff)await rpc(owner,'spa_daily_shift_save',[person,day,true,600,1320,'測試班表']);
}
async function book(day,start,who=null,phone='090'+String(++phoneNumber).padStart(7,'0')){const result=await rpc(null,'spa_create_booking',[randomUUID(),service,day,`${day}T${start}:00+08:00`,who,'整合測試客人',phone,0,'']);return (await db.query('select * from spa_appointments where manage_token=$1',[result.manage_token])).rows[0];}
let phoneNumber=1;
let slot=(await rows(null,'spa_public_slots',[service,date,null])).find(row=>row.time_label==='10:00');
check(slot.available_staff_count===4,'six eligible staff are capped by four beds');
const allocations=[];for(let i=0;i<3;i++)allocations.push(await book(date,'10:00'));
const identity=allocations[0],identityPhone=(await db.query('select phone from spa_customers where id=$1',[identity.customer_id])).rows[0].phone;
await reject(()=>rpc(null,'spa_create_booking',[randomUUID(),service,date,`${date}T17:00:00+08:00`,null,'竄改的姓名',identityPhone,0,'']),/CUSTOMER_NAME_MISMATCH/);
check((await db.query('select name from spa_customers where id=$1',[identity.customer_id])).rows[0].name==='整合測試客人','booking cannot overwrite the name used to access existing member history');
await reject(()=>rpc(null,'spa_create_booking',[identity.request_id,service,date,identity.starts_at,staff[1],'整合測試客人',identityPhone,0,'']),/REQUEST_CONFLICT/);
check((await rpc(null,'spa_create_booking',[identity.request_id,service,date,identity.starts_at,null,'整合測試客人',identityPhone,0,''])).reference===identity.reference,'identical booking retry returns the original receipt');
await db.query("update spa_customers set status='blocked' where id=$1",[identity.customer_id]);
await reject(()=>rpc(null,'spa_create_booking',[randomUUID(),service,date,`${date}T17:00:00+08:00`,null,'整合測試客人',identityPhone,0,'']),/CUSTOMER_UNAVAILABLE/);
check((await db.query('select status from spa_customers where id=$1',[identity.customer_id])).rows[0].status==='blocked','public booking cannot reactivate a blocked profile');
await db.query("update spa_customers set status='active',archived_at=now() where id=$1",[identity.customer_id]);
await reject(()=>rpc(null,'spa_create_booking',[randomUUID(),service,date,`${date}T17:00:00+08:00`,null,'整合測試客人',identityPhone,0,'']),/CUSTOMER_UNAVAILABLE/);
await rpc(owner,'spa_customer_restore',[identity.customer_id]);
slot=(await rows(null,'spa_public_slots',[service,date,null])).find(row=>row.time_label==='10:00');
check(slot.available_staff_count===1,'three occupied beds leave exactly one simultaneous slot');
const free=staff.find(person=>!allocations.some(booking=>booking.staff_id===person));
const allocationAccess=(await rpc(null,'spa_booking_link_access',[allocations[0].manage_token])).access_token;
await rpc(owner,'spa_time_off_save',[free,`${date}T12:00:00+08:00`,`${date}T13:00:00+08:00`,'休假測試']);
check(!(await rows(null,'spa_public_slots',[service,date,free])).find(row=>row.time_label==='12:00').available,'approved leave removes staff from public booking slots');
await reject(()=>rpc(null,'spa_customer_reschedule',[allocationAccess,allocations[0].id,randomUUID(),date,`${date}T12:00:00+08:00`,free,'想換時段']),/SLOT_TAKEN/);
check(!(await rows(owner,'spa_reschedule_availability',[allocations[0].id,date,free])).find(row=>row.time_label==='12:00').available,'owner and customer rescheduling respect the same leave');
check((await rpc(null,'spa_public_available_staff',[service,date,`${date}T17:00:00+08:00`])).every(row=>!('workload_minutes' in row)),'public technician choices do not expose private workload totals');
check((await rpc(null,'spa_public_available_staff',[service,date,`${date}T17:01:00+08:00`])).length===0,'time-first choices reject an unaligned start time');
check((await rpc(null,'spa_public_available_staff',[service,'2026-10-05','2026-10-05T10:15:00+08:00'])).length===0,'time-first choices obey the same thirty-minute lead time');
await reject(()=>rpc(employee,'spa_reschedule_availability',[allocations[0].id,date,null]),/FORBIDDEN/);
await reject(()=>rpc(null,'spa_reschedule_availability',[allocations[0].id,date,null]),/permission denied|FORBIDDEN/);

const original=await book(rosterDate,'14:00',staff[0]);
await db.query("update spa_appointments set status='in_service' where id=$1",[original.id]);
await reject(()=>db.query('insert into spa_time_off(staff_id,starts_at,ends_at,reason) values($1,$2,$3,$4)',[staff[0],`${rosterDate}T14:45:00+08:00`,`${rosterDate}T15:30:00+08:00`,'緩衝仍被占用']),/EXISTING_BOOKINGS/);
await reject(()=>rpc(owner,'spa_daily_shift_save',[staff[0],rosterDate,false,600,1320,'休班']),/EXISTING_BOOKINGS/);
await reject(()=>rpc(owner,'spa_business_day_override_save',[rosterDate,false,600,1320,'休店']),/EXISTING_BOOKINGS/);
await reject(()=>db.query("insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents) values($1,$2,$3,$4,$5,$6,$7,$8,$9,'in_service','測試療程',110000)",[randomUUID(),original.customer_id,staff[1],original.room_id,service,rosterDate,`${rosterDate}T14:15:00+08:00`,`${rosterDate}T15:00:00+08:00`,`${rosterDate}T15:15:00+08:00`]),/SLOT_TAKEN/);
const weekday=new Date(`${rosterDate}T00:00:00Z`).getUTCDay();
await rpc(owner,'spa_weekly_shift_save',[staff[0],weekday,true,600,720]);
await reject(()=>rpc(owner,'spa_daily_shift_delete',[staff[0],rosterDate]),/EXISTING_BOOKINGS/);
check((await db.query('select count(*) n from spa_daily_shifts where staff_id=$1 and business_date=$2',[staff[0],rosterDate])).rows[0].n===1,'unsafe single-day delete rolls back the roster');
await rpc(owner,'spa_weekly_shift_save',[staff[0],weekday,true,600,1320]);
await rpc(owner,'spa_daily_shift_delete',[staff[0],rosterDate]);
await reject(()=>rpc(owner,'spa_shift_save',[staff[0],weekday,600,720]),/EXISTING_BOOKINGS/);
check((await db.query('select end_minute from spa_shifts where staff_id=$1 and weekday=$2',[staff[0],weekday])).rows[0].end_minute===1320,'legacy weekly edit cannot strand a live booking');
await db.query('update spa_business_hours set closing_minute=720 where weekday=$1',[weekday]);
await reject(()=>rpc(owner,'spa_business_day_override_delete',[rosterDate]),/EXISTING_BOOKINGS/);
await db.query('update spa_business_hours set closing_minute=1320 where weekday=$1',[weekday]);
await rpc(owner,'spa_time_off_save',[staff[0],`${rosterDate}T15:00:00+08:00`,`${rosterDate}T16:00:00+08:00`,'緩衝結束後可休假']);
check((await db.query('select count(*) n from spa_time_off where staff_id=$1',[staff[0]])).rows[0].n>=1,'leave may start exactly at the cleanup boundary');

await db.query("update spa_appointments set status='confirmed' where id=$1",[original.id]);
await db.query('update spa_services set duration_minutes=15,buffer_minutes=0 where id=$1',[service]);
check((await rows(null,'spa_availability',[service,rosterDate,staff[0]])).find(row=>row.time_label==='21:30').available,'new shorter service can fit the late slot');
check(!(await rows(owner,'spa_reschedule_availability',[original.id,rosterDate,staff[0]])).find(row=>row.time_label==='21:30').available,'existing longer purchase cannot fit that late slot');
await reject(()=>rpc(owner,'spa_reschedule',[original.id,rosterDate,`${rosterDate}T21:30:00+08:00`,staff[0],'移至晚間']),/SLOT_TAKEN/);
check(Date.parse((await db.query('select starts_at from spa_appointments where id=$1',[original.id])).rows[0].starts_at)===Date.parse(original.starts_at),'failed reschedule preserves original allocation');
await rpc(owner,'spa_reschedule',[original.id,rosterDate,`${rosterDate}T17:00:00+08:00`,staff[0],'正常改期']);
const moved=(await db.query('select * from spa_appointments where id=$1',[original.id])).rows[0];
check(Date.parse(moved.blocked_until)-Date.parse(moved.starts_at)===Date.parse(original.blocked_until)-Date.parse(original.starts_at),'reschedule preserves purchased duration plus cleanup');
await db.query("update spa_services set active=false,status='archived',online_booking_enabled=false where id=$1",[service]);
check((await rows(owner,'spa_reschedule_availability',[original.id,rosterDate,staff[0]])).some(row=>row.available),'owner can honor an existing booking after catalog archival');
const originalAccess=(await rpc(null,'spa_booking_link_access',[original.manage_token])).access_token;
check(!(await rows(null,'spa_customer_availability',[originalAccess,original.id,rosterDate,staff[0]])).some(row=>row.available),'public reschedule does not revive an archived service');

// Owner-approved over-cap rest days must not block an unchanged resubmission.
await rpc(owner,'spa_schedule_policy_save',[0]);
await rpc(owner,'spa_daily_shift_save',[staff[0],'2026-11-20',false,600,1320,'已核准休班']);
const plan=await rpc(employee,'spa_staff_schedule_plan');
const draft=plan.days.map(row=>({date:row.business_date,is_working:row.is_working,start_minute:row.start_minute??600,end_minute:row.end_minute??1320}));
check(!!await rpc(employee,'spa_staff_schedule_submit',[plan.target_month,draft]),'unchanged owner-approved rest remains resubmittable under a stricter cap');
const newRest=draft.find(row=>row.is_working&&row.date!=='2026-11-12'&&row.date!==rosterDate);newRest.is_working=false;
await reject(()=>rpc(employee,'spa_staff_schedule_submit',[plan.target_month,draft]),/OFF_LIMIT/);
await db.query("update consistency_test_clock set at_time='2026-10-08T00:00:00+08:00'");
const request=await rpc(employee,'spa_staff_schedule_request',['2026-11-21',true,600,1320,'長'.repeat(600)]);
await rpc(owner,'spa_staff_schedule_request_review',[request,true,'已核准']);
check((await db.query('select length(note) n from spa_daily_shifts where staff_id=$1 and business_date=$2',[staff[0],'2026-11-21'])).rows[0].n===500,'long accepted reason is preserved in the request and safely summarized on the shift');

await db.query('delete from spa_daily_shifts where staff_id=$1',[staff.at(-1)]);
await db.query('delete from spa_shifts where staff_id=$1',[staff.at(-1)]);
await db.query('update spa_roles set staff_id=$2 where user_id=$1',[employee,staff.at(-1)]);
await db.query("update consistency_test_clock set at_time='2026-10-05T10:00:00+08:00'");
const firstPlan=await rpc(employee,'spa_staff_schedule_plan');
check(firstPlan.days.every(row=>!row.is_working&&row.end_minute>row.start_minute),'new unrostered employee gets valid draft times on rest days');
const firstDraft=firstPlan.days.map(row=>({date:row.business_date,is_working:false,start_minute:row.start_minute,end_minute:row.end_minute}));
firstDraft[0].is_working=true;
check(!!await rpc(employee,'spa_staff_schedule_submit',[firstPlan.target_month,firstDraft]),'new employee can submit a first month without a weekly template');

console.log(`Booking consistency checks passed: ${checks}`);await db.close();
