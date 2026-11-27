process.on('uncaughtException',error=>{console.error(error.stack?.split('\n').filter(line=>!line.includes('/node_modules/')).join('\n')||error.message);if(error.where)console.error(error.where);process.exit(1);});
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {classificationPayload,staffClassification,technicianRanks} from '../src/lib/staff-work-roles.js';

const db=new PGlite(),owner=randomUUID(),employee=randomUUID(),custom=randomUUID();
let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
const one=async(sql,args=[])=>(await q(sql,args))[0];
async function rpc(name,args=[],user=owner){
 await db.exec('begin');
 try{
  await db.exec('set local role '+(user?'authenticated':'anon'));
  await q("select set_config('request.jwt.claim.sub',$1,true)",[user||'']);
  const rows=await q('select '+(name==='spa_availability'?'* from public.':'public.')+name+'('+args.map((_,i)=>'$'+(i+1)).join(',')+')'+(name==='spa_availability'?'':' result'),args);
  const result=name==='spa_availability'?rows:rows[0].result;
  await db.exec('commit');return result;
 }catch(error){await db.exec('rollback');throw error;}
}
const rejects=async(fn,pattern)=>{await assert.rejects(fn,pattern);checks++;};
try{
 await db.exec(`create role anon;create role authenticated;create role service_role;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;
 grant usage on schema auth to anon,authenticated;
 create schema realtime;create function realtime.send(jsonb,text,text,boolean) returns void language sql as $$select$$;
 create function public.hierarchy_test_clock() returns timestamptz language sql stable as $$select '2026-11-27T12:00:00+08:00'::timestamptz$$;`);
 const dir=new URL('../supabase/migrations/',import.meta.url);
 for(const file of (await readdir(dir)).sort())await db.exec((await readFile(new URL(file,dir),'utf8')).replaceAll('now()','public.hierarchy_test_clock()'));
 await q("insert into auth.users values($1,'owner@example.test'),($2,'employee@example.test'),($3,'custom@example.test')",[owner,employee,custom]);
 await q("insert into spa_roles(user_id,role,active)values($1,'owner',true)",[owner]);
 await db.exec("update spa_staff set active=false,employment_status='inactive'");
 const titles=await q('select * from spa_job_titles'),service=(await one("select id from spa_services where active and status='active' and online_booking_enabled order by duration_minutes limit 1")).id;
 const create=async(name,category,rankCode)=>{
  const identity=classificationPayload({role:'technician',category,rankCode},titles);
  check(!!identity,'HR classification maps to an existing job');
  const body={...identity,name,hire_date:'2026-08-01',employment_status:'active',is_bookable:true,website_visible:true,
   contract_started_on:category==='04'?'2026-09-01':'',services:[service]};
  const id=await rpc('spa_staff_profile_save_v2',[body]);return {id,body};
 };
 check(technicianRanks.length===6,'there are exactly six HR ranks');
 check(!titles.find(row=>row.code==='ft_senior_advanced').active,'senior advanced rank is unavailable for new assignments');
 const full=await create('測試正職','01','ft_junior');
 const monthly=await create('測試月薪','02','ft_junior');
 const hourly=await create('測試時薪','03','');
 const contractor=await create('測試承攬','04','');
 const trial=await create('測試試用','01','ft_probation');
 for(const category of ['01','02'])for(const [code] of technicianRanks){
  const identity=classificationPayload({role:'technician',category,rankCode:code},titles);
  check(!!identity&&identity.employment_type_code===(category==='01'?'full_time':'part_time'),'every monthly rank has the correct employment type');
 }
 check(classificationPayload({role:'technician',category:'02',rankCode:'ft_senior_advanced'},titles)===null,'removed rank cannot be selected');
 check(staffClassification({payroll_category_code:'02'},titles.find(t=>t.code==='ft_junior')).category==='02','monthly part-time is preserved when editing');
 const counterBody={...classificationPayload({role:'counter',counterEmployment:'full_time'},titles),name:'測試櫃檯',employment_status:'active',hire_date:'2026-08-01',services:[]};
 const counter=await rpc('spa_staff_profile_save_v2',[counterBody]);
 check((await one('select is_bookable from spa_staff where id=$1',[counter])).is_bookable===false,'counter cannot accidentally accept treatment bookings');
 await rejects(()=>rpc('spa_staff_profile_save_v2',[{...monthly.body,payroll_category_code:'03'}]),/JOB_EMPLOYMENT_MISMATCH/);
 const rule=await rpc('spa_payroll_notice_setup',['2026-12-01']);
 let packet=await rpc('spa_payroll_notice_get',[rule]);
 check(packet.assignments.length===0,'global policy contains no employee assignments');
 check(!packet.technician_ids.includes(counter),'counter does not enter technician wages');
 check((await one("select rank_no from spa_private.payroll_classification_on($1,'2026-12-01',$2)",[monthly.id,rule])).rank_no===2,'monthly part-time rank is read from dated HR');
 await rpc('spa_staff_profile_save_v2',[{...hourly.body,id:hourly.id,...classificationPayload({role:'technician',category:'02',rankCode:'ft_mid'},titles)}]);
 packet=await rpc('spa_payroll_notice_get',[rule]);
 check((await one("select category,rank_no from spa_private.payroll_classification_on($1,'2026-12-01',$2)",[hourly.id,rule])).rank_no===4,'HR edits update independent classification atomically');
 check((await one('select count(*)::int n from spa_private.payroll_notice_staff where rule_id=$1',[rule])).n===0,'HR edits never create policy/person links');
 const preview=await rpc('spa_payroll_preview',['2026-12-01','2026-12-31',rule]);
 check(preview.find(a=>a.staff_id===full.id).base_cents===3100000,'full-time document salary is unchanged');
 check(preview.find(a=>a.staff_id===monthly.id).base_cents===2520000,'monthly part-time salary uses the shared base');
 check(preview.find(a=>a.staff_id===hourly.id).base_cents===2520000,'changed monthly classification keeps the same shared base');
 for(const staff of [full,monthly,hourly,contractor,trial]){
  const source=await rpc('spa_payroll_sources',[staff.id,'2026-12-01','2026-12-31',rule]);
  check(source.reconciliation.source_matches&&source.reconciliation.formula_matches,'wage component totals reconcile with their source references');
 }
 // Every HR rank must retain the same monthly base and the original
 // grade-specific commission rate. A stale per-rank amount is rejected.
 check(packet.monthly_base_cents===2520000,'the policy exposes one shared monthly amount');
 for(const [index,[rankCode]] of technicianRanks.entries()){
  await rpc('spa_staff_profile_save_v2',[{...monthly.body,id:monthly.id,...classificationPayload({role:'technician',category:'02',rankCode},titles)}]);
  const wages=await rpc('spa_payroll_preview',['2026-12-01','2026-12-31',rule]);
  const salary=wages.find(row=>row.staff_id===monthly.id);
  check(salary.base_cents===2520000&&salary.notice_rank===index+1,'all six ranks retain NT$25,200 after HR edits');
  check(salary.service_commission_bps===index*500,'promotion retains its original service commission rate');
 }
 packet=await rpc('spa_payroll_notice_get',[rule]);
 await rejects(()=>rpc('spa_payroll_notice_save',[rule,packet,packet.ranks.map(row=>({...row,monthly_base_cents:row.rank_no===2?2560000:2520000}))]),/PAYROLL_MONTHLY_BASE_MISMATCH/);
 check((await rpc('spa_payroll_notice_get',[rule])).ranks.every(row=>row.monthly_base_cents===2520000),'a mismatched save leaves all six amounts unchanged');
 // One owner-editable field updates all compatibility rows together.
 await rpc('spa_payroll_notice_save',[rule,{...packet,monthly_base_cents:2540000},packet.ranks.map(row=>({...row,monthly_base_cents:2540000}))]);
 check((await rpc('spa_payroll_notice_get',[rule])).ranks.every(row=>row.monthly_base_cents===2540000),'editing the shared setting updates every grade together');
 await rpc('spa_payroll_notice_save',[rule,{...packet,monthly_base_cents:2520000},packet.ranks.map(row=>({...row,monthly_base_cents:2520000}))]);
 await rpc('spa_payroll_notice_activate',[rule]);
 check((await one("select spa_private.payroll_notice_rule_on('2026-11-30') id")).id!==rule,'published future version does not change November');
 check((await one("select spa_private.payroll_notice_rule_on('2026-12-01') id")).id===rule,'published future version becomes applicable on December 1');
 await rejects(()=>rpc('spa_payroll_run_save',['2026-12-01','2026-12-31',rule,true]),/PAYROLL_POLICY_NOT_EFFECTIVE/);
 await rpc('spa_staff_profile_save_v2',[{...full.body,id:full.id,...classificationPayload({role:'technician',category:'01',rankCode:'ft_mid'},titles)}]);
 check((await one('select job_title_id from spa_staff where id=$1',[full.id])).job_title_id===titles.find(t=>t.code==='ft_mid').id,'active policy does not prevent an HR promotion');
 await q("insert into spa_roles(user_id,role,staff_id,active,login_name)values($1,'therapist',$2,true,'hierarchy_test')",[employee,full.id]);
 await rpc('spa_role_profile_save',['custom_tech','測試自訂技師',['dashboard.view','appointments.view'],true,90]);
 await q("insert into spa_roles(user_id,role,staff_id,active,login_name)values($1,'custom_tech',$2,true,'custom_hierarchy')",[custom,monthly.id]);
 const monthlyPlan=await rpc('spa_staff_schedule_plan',[],custom);
 check(monthlyPlan.schedule_reminder.role_code==='part_time_monthly','employee schedule reads the same monthly HR category before the future policy starts');
 check(monthlyPlan.scheduling_mode==='free','flat monthly pay introduces no required day count');
 await rpc('spa_daily_shift_save',[monthly.id,'2026-12-02',true,600,780,'測試兼職月薪班表']);
 check((await rpc('spa_staff_schedule_plan',[],custom)).days.find(day=>day.business_date==='2026-12-02').is_working,'monthly employee sees the saved schedule');
 check((await rpc('spa_availability',[service,'2026-12-02',monthly.id],null)).some(slot=>slot.available),'monthly shift opens the same employee for public booking');
 await rpc('spa_daily_shift_save',[monthly.id,'2026-12-02',false,600,780,'測試休班']);
 check(!(await rpc('spa_availability',[service,'2026-12-02',monthly.id],null)).some(slot=>slot.available),'rest day removes public availability');
 const ownPay=await rpc('spa_staff_self',['2026-12-01','2026-12-31'],custom);
 check(ownPay.profile.base_pay_cents===2520000&&ownPay.payroll.base_cents===2520000,'employee profile and wage detail share the monthly base despite a changed day count');
 const monthlySources=await rpc('spa_payroll_sources',[monthly.id,'2026-12-01','2026-12-31',rule]);
 check(monthlySources.reconciliation.source_matches&&monthlySources.reconciliation.formula_matches,'roster changes preserve wage source and component reconciliation');
 for(const staff of [full,monthly])await rpc('spa_daily_shift_save',[staff.id,'2026-11-28',true,600,1320,'測試班表']);
 const slots=await rpc('spa_availability',[service,'2026-11-28',full.id],null);
 const start=slots.find(a=>a.available).starts_at;
 const own=await rpc('spa_create_booking',[randomUUID(),service,'2026-11-28',start,full.id,'測試客甲','0912345611',0,''],null);
 const otherStart=(await rpc('spa_availability',[service,'2026-11-28',monthly.id],null)).find(a=>a.available&&a.starts_at>slots.find(a=>a.starts_at===start).ends_at)?.starts_at || slots.filter(a=>a.available).at(-1).starts_at;
 const peer=await rpc('spa_create_booking',[randomUUID(),service,'2026-11-28',otherStart,monthly.id,'測試客乙','0912345612',0,''],null);
 const mine=await rpc('spa_admin_bookings',['2026-11-01','2026-12-31'],employee);
 check(mine.length===1&&mine[0].staff_id===full.id,'date-range API only returns assigned technician bookings');
 const colleagues=await rpc('spa_admin_bookings',['2026-11-01','2026-12-31'],custom);
 check(colleagues.length===1&&colleagues[0].staff_id===monthly.id,'custom roles cannot bypass technician scope');
 check((await rpc('spa_admin_bookings',['2026-11-01','2026-12-31'])).length===2,'owner retains the store-wide booking workbench');
 const calendar=await rpc('spa_monthly_operations',['2026-11-01'],employee),day=calendar.days.find(a=>a.date==='2026-11-28');
 check(day.appointments.length===1&&day.appointment_count===1&&day.appointments[0].staff_id===full.id,'calendar details and booking counts use the same own scope');
 check(day.shifts.length===2,'shared staff work roster remains available without peers customer appointments');
 check((await rpc('spa_session',[],employee)).own_bookings_only===true,'session exposes the actual scope to the UI');
 await rejects(()=>rpc('spa_admin_bookings',['2026-11-01','2026-12-31'],null),/FORBIDDEN|permission denied/);
 // Reassignment must move the booking to the actual technician, not original preference.
 const peerRow=(await one('select id from spa_appointments where manage_token=$1',[peer.manage_token]));
 await rpc('spa_appointment_reassign',[peerRow.id,full.id,'測試實際服務技師歸屬']);
 check((await rpc('spa_admin_bookings',['2026-11-01','2026-12-31'],employee)).length===2,'new actual technician sees reassigned appointment');
 check((await rpc('spa_admin_bookings',['2026-11-01','2026-12-31'],custom)).length===0,'previous technician no longer sees reassigned appointment');
 // The one-time production cleanup must reject business references and
 // remove only the exact disposable, already archived seed identities.
 await db.exec("update spa_staff set archived_at=public.hierarchy_test_clock() where name in ('陳柏翰','王詩涵','張家豪','李靜怡','吳俊霖')");
 const demo=(await one("select id from spa_staff where name='王詩涵'")).id;
 const blocker=(await one("insert into spa_time_entries(staff_id,work_date,started_at,ended_at,break_minutes,status)values($1,'2026-11-01','2026-11-01T10:00:00+08:00','2026-11-01T11:00:00+08:00',0,'draft')returning id",[demo])).id;
 const cleanup=await readFile(new URL('../docs/maintenance/2026-11-27-production-cleanup.sql',import.meta.url),'utf8');
 await rejects(()=>db.exec(cleanup),/DEMO_HAS_BUSINESS_HISTORY/);
 await db.exec('rollback');
 check(!!(await one('select id from spa_staff where id=$1',[demo])),'blocked cleanup retains the original staff record');
 await q('delete from spa_time_entries where id=$1',[blocker]);
 await db.exec(cleanup);
 check((await one("select count(*)::int n from spa_staff where name in ('陳柏翰','王詩涵','張家豪','李靜怡','吳俊霖')")).n===0,'exact unused seed identities are removed after all dependency guards pass');
 check((await one('select count(*)::int n from spa_staff where id=any($1)',[[full.id,monthly.id,hourly.id,contractor.id,trial.id,counter]])).n===6,'cleanup preserves every real synthetic employee and counter');
 console.log(`PASS: ${checks} HR hierarchy, draft mapping, payroll sources, scheduled publication and own-booking assertions`);
}finally{await db.close();}
