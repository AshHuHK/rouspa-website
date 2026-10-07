process.on('uncaughtException',e=>{console.error(e.message);if(e.where)console.error(e.where);process.exit(1);});
import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const db=new PGlite();let checks=0;const check=(ok,label)=>{assert.ok(ok,label);checks++;};const reject=async(fn,pattern)=>{await assert.rejects(fn,pattern);checks++;};
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).sort()){
 let sql=await readFile(new URL(file,directory),'utf8');
 if(file==='202610070001_staff_schedule_booking_flow.sql'){
  await db.exec(`create table public.schedule_test_clock(at_time timestamptz);insert into public.schedule_test_clock values('2026-10-05T10:00:00+08:00');create function spa_private.schedule_test_now() returns timestamptz language sql stable as $$select at_time from public.schedule_test_clock$$;`);
  sql=sql.replaceAll('now()','spa_private.schedule_test_now()');
 }
 await db.exec(sql);
}
const owner=randomUUID(),employee=randomUUID(),staff=(await db.query("select id from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)',[owner,'owner@schedule.test',employee,'staff@schedule.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name) values($1,'owner',null,true,null),($2,'therapist',$3,true,'schedule_staff')",[owner,employee,staff[0].id]);
async function as(role,user,sql,args=[]){await db.exec('begin');try{await db.exec(`set local role ${role}`);await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat:1800000000})]);const result=await db.query(sql,args);await db.exec('commit');return result.rows;}catch(e){await db.exec('rollback');throw e;}}
async function call(user,name,args=[]){return (await as(user?'authenticated':'anon',user,`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args))[0]?.result;}
const clock=at=>db.query('update schedule_test_clock set at_time=$1',[at]);
await reject(()=>call(null,'spa_staff_schedule_plan',[]),/FORBIDDEN|permission denied/);
let plan=await call(employee,'spa_staff_schedule_plan',[]);
check(plan.edit_open&&plan.target_month==='2026-11-01'&&plan.days.length===30,'Taiwan server date opens exactly next month on days 1-7');
await reject(()=>call(employee,'spa_staff_schedule_submit',['2026-11-01',plan.days.slice(1)]),/INVALID_SCHEDULE/);
await call(owner,'spa_schedule_policy_save',[20]);
const days=plan.days.map(row=>({date:row.business_date,is_working:row.is_working,start_minute:row.start_minute,end_minute:row.end_minute}));
const editable=days.find(row=>row.is_working)||days[0];editable.is_working=true;editable.start_minute=720;editable.end_minute=1320;
let submission=await call(employee,'spa_staff_schedule_submit',['2026-11-01',days]);
check(submission.version===1,'complete draft writes one submitted schedule version');
submission=await call(employee,'spa_staff_schedule_submit',['2026-11-01',days]);
check(submission.version===2,'employee may resubmit through day 7 and last version wins');
let admin=await call(owner,'spa_schedule_admin',[]);
check(admin.staff.find(row=>row.id===staff[0].id).submission.version===2,'owner sees who submitted and the current version');
await clock('2026-10-08T00:00:00+08:00');
await reject(()=>call(employee,'spa_staff_schedule_submit',['2026-11-01',days]),/SCHEDULE_LOCKED/);
const requestDate='2026-11-11';
const request=await call(employee,'spa_staff_schedule_request',[requestDate,true,660,1200,'家庭安排，需要調整班別']);
admin=await call(owner,'spa_schedule_admin',[]);check(admin.requests.some(row=>row.id===request&&row.status==='pending'),'locked edit becomes an owner-visible change request');
await reject(()=>call(employee,'spa_staff_schedule_request_review',[request,true,'self approval']),/FORBIDDEN/);
await call(owner,'spa_staff_schedule_request_review',[request,true,'已核對人力']);
check((await db.query('select start_minute,end_minute from spa_daily_shifts where staff_id=$1 and business_date=$2',[staff[0].id,requestDate])).rows[0].start_minute===660,'owner approval applies the dated shift');
const service=(await db.query("select id from spa_services where active and status='active' and online_booking_enabled order by display_order limit 1")).rows[0].id;
await db.query("insert into spa_staff_services(staff_id,service_id,enabled) values($1,$2,true) on conflict(staff_id,service_id) do update set enabled=true",[staff[0].id,service]);
await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note) values($1,'2026-11-12',true,600,1320,'test') on conflict(staff_id,business_date) do update set is_working=true,start_minute=600,end_minute=1320",[staff[0].id]);
const october=await call(null,'spa_booking_calendar',[service,'2026-10-01',null]),november=await call(null,'spa_booking_calendar',[service,'2026-11-01',staff[0].id]);
check(october.days.length===31&&november.days.length===30,'public calendar exposes exactly current and next calendar month');
await reject(()=>call(null,'spa_booking_calendar',[service,'2026-12-01',null]),/INVALID_DATE/);
const openDay=november.days.find(row=>row.date==='2026-11-12');check(openDay.status==='open'&&openDay.start_minute===600&&openDay.available_slots>0,'calendar availability comes from selected employee dated roster');
const slots=await as('anon',null,'select * from public.spa_public_slots($1,$2,$3)',[service,'2026-11-12',staff[0].id]),slot=slots.find(row=>row.available);
check(slot&&slot.available_staff_count>=1,'public slot reports the available staff count');
const choices=await call(null,'spa_public_available_staff',[service,'2026-11-12',slot.starts_at]);
check(choices.some(row=>row.id===staff[0].id),'time-first flow lists staff eligible at the chosen slot');
const booking=await call(null,'spa_create_booking',[randomUUID(),service,'2026-11-12',slot.starts_at,staff[0].id,'排班測試客人','0900000022',0,'']);
check(booking.staff_id===staff[0].id&&booking.booking_preference==='designated'&&booking.staff_name,'booking receipt records requested and assigned therapist');
const blockedRequest=await call(employee,'spa_staff_schedule_request',['2026-11-12',false,600,1320,'臨時需要休假']);
await reject(()=>call(owner,'spa_staff_schedule_request_review',[blockedRequest,true,'approve']),/EXISTING_BOOKINGS/);
await clock('2026-12-01T10:00:00+08:00');
check((await call(employee,'spa_staff_schedule_plan',[])).target_month==='2027-01-01','target month rolls automatically at month and year boundaries');
console.log(`Schedule and booking checks passed: ${checks}`);await db.close();
