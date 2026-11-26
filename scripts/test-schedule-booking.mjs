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
 }
 if(file>='202610070001_staff_schedule_booking_flow.sql')sql=sql.replaceAll('now()','spa_private.schedule_test_now()');
 await db.exec(sql);
}
const owner=randomUUID(),employee=randomUUID(),staff=(await db.query("select id from spa_staff where active and employment_status='active' and is_bookable order by display_order limit 2")).rows;
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
// Role reminders are prose, never scheduling qualifications.
await call(owner,'spa_schedule_policy_save',[0]);
const rule=(await db.query("select id from spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1")).rows[0].id;
await db.query("update spa_payroll_rule_versions set effective_from='2026-10-01' where id=$1",[rule]);
await db.query('insert into spa_private.payroll_notices(rule_id) values($1) on conflict do nothing',[rule]);
await db.query('insert into spa_private.payroll_notice_ranks(rule_id,rank_no,full_time_start_bps,monthly_start_bps,monthly_base_cents) values($1,1,0,0,2520000) on conflict do nothing',[rule]);
const reminderRows=(await call(owner,'spa_team_os')).schedule_reminders;
check(reminderRows.length===4&&reminderRows.some(row=>row.role_code==='contractor'&&row.reminder_text.includes('20天')),'four role reminders match the supplied initial text');
await reject(()=>as('authenticated',employee,'select * from spa_schedule_role_reminders'),/permission denied/);
const full=reminderRows.find(row=>row.role_code==='full_time');
await reject(()=>call(employee,'spa_schedule_reminder_save',[full.role_code,'employee edit',full.version]),/FORBIDDEN/);
await call(owner,'spa_schedule_reminder_save',[full.role_code,'可自行安排「上班日期」與時間。',full.version]);
await reject(()=>call(owner,'spa_schedule_reminder_save',[full.role_code,'stale',full.version]),/SCHEDULE_REMINDER_STALE/);
const roles={'01':'full_time','02':'part_time_monthly','03':'part_time_hourly','04':'contractor'};
for(const [category,role] of Object.entries(roles)){
 await db.query("insert into spa_private.payroll_notice_staff(rule_id,staff_id,category,rank_no,contract_from) values($1,$2,$3,$4,$5) on conflict(rule_id,staff_id) do update set category=excluded.category,rank_no=excluded.rank_no,contract_from=excluded.contract_from,start_bps=null",[rule,staff[0].id,category,['01','02'].includes(category)?1:null,category==='04'?'2026-01-01':null]);
 const rolePlan=await call(employee,'spa_staff_schedule_plan');
 check(rolePlan.schedule_reminder.role_code===role&&rolePlan.scheduling_mode==='free','current effective role automatically selects reminder '+category);
 const sparse=rolePlan.days.map((row,index)=>({date:row.business_date,is_working:index===0,start_minute:617,end_minute:662}));
 check(!!await call(employee,'spa_staff_schedule_submit',[rolePlan.target_month,sparse]),'one 45 minute workday with weekends off is accepted for '+category);
 const allOff=sparse.map(row=>({...row,is_working:false}));
 check(!!await call(employee,'spa_staff_schedule_submit',[rolePlan.target_month,allOff]),'zero workdays accepted for '+category);
 const allOn=sparse.map(row=>({...row,is_working:true}));
 check(!!await call(employee,'spa_staff_schedule_submit',[rolePlan.target_month,allOn]),'all dates selectable without a role max for '+category);
}
await db.query("update spa_private.payroll_notice_staff set category='01',rank_no=1,contract_from=null where rule_id=$1 and staff_id=$2",[rule,staff[0].id]);
let displayed=(await call(employee,'spa_staff_schedule_plan')).schedule_reminder;
check(displayed.text==='可自行安排「上班日期」與時間。','edited role text is shared automatically with its employee');
await call(owner,'spa_schedule_reminder_save',['full_time','',displayed.version]);
check((await call(employee,'spa_staff_schedule_plan')).schedule_reminder.text==='','cleared role text remains empty instead of restoring defaults');
displayed=(await call(employee,'spa_staff_schedule_plan')).schedule_reminder;
await call(owner,'spa_schedule_reminder_save',['full_time',full.reminder_text,displayed.version]);
await reject(()=>call(owner,'spa_schedule_reminder_save',['unknown','text',1]),/INVALID_INPUT/);
await reject(()=>call(owner,'spa_schedule_reminder_save',['full_time','長'.repeat(4001),displayed.version+1]),/INVALID_INPUT/);
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
