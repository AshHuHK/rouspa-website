process.on('uncaughtException',e=>{console.error(e.message);if(e.where)console.error(e.where);process.exit(1);});
import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir,writeFile,mkdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
import {attendanceMinutes,taipeiInput,attendanceStamp} from '../src/lib/attendance.js';
const db=new PGlite();let checks=0;const check=(ok,label)=>{assert.ok(ok,label);checks++;};const reject=async(fn,pattern=/FORBIDDEN|permission denied/)=>{await assert.rejects(fn,pattern);checks++;};
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).sort()){
 let sql=await readFile(new URL(file,directory),'utf8');
 if(file==='202610060001_employee_attendance.sql'){
  // Controlled clock in this local test database only. Production uses server now().
  await db.exec(`create table public.attendance_test_clock(at_time timestamptz);insert into public.attendance_test_clock values('2026-10-06T10:00:00+08:00');create function spa_private.attendance_test_now() returns timestamptz language sql stable as $$select at_time from public.attendance_test_clock$$;`);
  sql=sql.replaceAll('now()','spa_private.attendance_test_now()');
 }
 await db.exec(sql);
}
const owner=randomUUID(),employee=randomUUID(),other=randomUUID(),staff=(await db.query("select id from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)',[owner,'owner@example.test',employee,'staff@example.test',other,'other@example.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name) values($1,'owner',null,true,null),($2,'therapist',$3,true,'attendance_test'),($4,'therapist',$5,true,'attendance_other')",[owner,employee,staff[0].id,other,staff[1].id]);
async function as(role,user,sql,args=[]){await db.exec('begin');try{await db.exec(`set local role ${role}`);await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat:Math.floor(Date.now()/1000)})]);const result=await db.query(sql,args);await db.exec('commit');return result.rows;}catch(e){await db.exec('rollback');throw e;}}
async function call(user,name,args=[]){return (await as(user?'authenticated':'anon',user,`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args))[0]?.result;}
const clock=async at=>db.query('update attendance_test_clock set at_time=$1',[at]);
const range=['2026-10-01','2026-10-31'];
await reject(()=>call(null,'spa_attendance_self',range));await reject(()=>call(employee,'spa_attendance_admin',range));await reject(()=>call(employee,'spa_attendance_setting_save',[23,120,100,50,5,1440,'store']));
for(const table of ['spa_attendance','spa_attendance_events','spa_attendance_requests','spa_attendance_settings']){await reject(()=>as('anon',null,`select * from ${table}`));await reject(()=>as('authenticated',employee,`select * from ${table}`));}
const settings=(await call(owner,'spa_attendance_admin',range)).settings;
check(settings.latitude===23.4768128&&settings.longitude===120.4431785&&settings.radius_m===100,'existing address marker coordinates and initial radius');
await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute) values($1,'2026-10-06',true,600,1080)",[staff[0].id]);
const loc=[settings.latitude,settings.longitude,8];
const punch=(user,id,kind,location=loc,reason='',err='',rest=0)=>call(user,'spa_attendance_punch',[id,kind,...location,reason,err,rest]);
await reject(()=>punch(employee,randomUUID(),'out'),/ATTENDANCE_NOT_IN/);
await reject(()=>punch(employee,randomUUID(),'in',[NaN,120,8]),/INVALID_LOCATION/);
await reject(()=>punch(employee,randomUUID(),'in',[null,null,null]),/INVALID_LOCATION/);
await reject(()=>punch(employee,randomUUID(),'in',[24,121,8]),/ATTENDANCE_REASON_REQUIRED/);
await reject(()=>punch(employee,randomUUID(),'in',[...loc.slice(0,2),90]),/ATTENDANCE_REASON_REQUIRED/);
const request=randomUUID(),first=await punch(employee,request,'in');
check(first.status==='open'&&Date.parse(first.clock_in)===Date.parse('2026-10-06T10:00:00+08:00'),'clock-in records server time');
check((await punch(employee,request,'in')).id===first.id,'network retry is idempotent');
await reject(()=>punch(other,request,'in'),/REQUEST_CONFLICT/);await reject(()=>punch(employee,request,'out'),/REQUEST_CONFLICT/);
await reject(()=>punch(employee,randomUUID(),'in'),/ATTENDANCE_ALREADY_IN/);
check((await call(other,'spa_attendance_self',range)).rows.length===0,'another employee cannot read attendance or location');
await reject(()=>call(other,'spa_attendance_request',[randomUUID(),first.id,'2026-10-06','2026-10-06T10:00:00+08:00','2026-10-06T11:00:00+08:00',0,'foreign']),/INVALID_INPUT|FORBIDDEN/);
await clock('2026-10-06T18:00:35+08:00');const closed=await punch(employee,randomUUID(),'out',loc,'','',30);
check(closed.status==='pending'&&Date.parse(closed.clock_out)===Date.parse('2026-10-06T18:00:35+08:00'),'clock-out remains pending');
check((await db.query('select count(*)::int n from spa_time_entries')).rows[0].n===0,'unreviewed clock-out never creates paid hours');
const review=[closed.id,closed.version,true,closed.effective_start,closed.effective_end,30,'核對班表與實際出勤'];
await reject(()=>call(employee,'spa_attendance_review',review));await call(owner,'spa_attendance_review',review);
let row=(await call(owner,'spa_attendance_admin',range)).rows.find(r=>r.id===closed.id);
check(row.status==='approved'&&row.time_entry_id,'approval links exactly one salary time entry');
const entry=(await db.query('select * from spa_time_entries where id=$1',[row.time_entry_id])).rows[0];
check(Math.floor((Date.parse(entry.ended_at)-Date.parse(entry.started_at))/60000)-entry.break_minutes===450,'eight hours minus 30-minute break, floor partial minute');
const preview=await call(owner,'spa_payroll_preview',[...range,null]);check(Number(preview.find(r=>r.staff_id===staff[0].id).work_minutes)===450,'existing payroll preview consumes approved attendance exactly');
await reject(()=>call(owner,'spa_attendance_review',review),/ATTENDANCE_STALE/);
await reject(()=>call(owner,'spa_time_entry_save',[row.time_entry_id,staff[0].id,'2026-10-06',entry.started_at,entry.ended_at,0,'bypass']),/ATTENDANCE_LINKED_ENTRY/);
await reject(()=>call(owner,'spa_time_entry_save',[null,staff[0].id,'2026-10-06',entry.started_at,entry.ended_at,0,'duplicate']),/ATTENDANCE_OVERLAP/);
const correctionId=randomUUID();const correction=[correctionId,row.id,'2026-10-06','2026-10-06T10:15:00+08:00','2026-10-06T18:00:00+08:00',30,'更正開始時間'];
const correctionRequest=await call(employee,'spa_attendance_request',correction);check(await call(employee,'spa_attendance_request',correction)===correctionRequest,'correction submission retry is idempotent');
await reject(()=>call(employee,'spa_attendance_request',[randomUUID(),...correction.slice(1)]),/ATTENDANCE_REQUEST_PENDING/);
await reject(()=>call(employee,'spa_attendance_request_review',[correctionRequest,true,'self approve']));
await call(owner,'spa_attendance_request_review',[correctionRequest,true,'確認更正']);
row=(await call(owner,'spa_attendance_admin',range)).rows.find(r=>r.id===closed.id);
check(row.clock_in===first.clock_in&&Date.parse(row.effective_start)===Date.parse('2026-10-06T10:15:00+08:00'),'correction preserves original punch');
check((await db.query('select count(*)::int n from spa_time_entries')).rows[0].n===1,'correction updates linked entry without duplication');
check(Number((await call(owner,'spa_payroll_preview',[...range,null])).find(r=>r.staff_id===staff[0].id).work_minutes)===435,'corrected work minutes match payroll');
const rule=(await db.query("select id from spa_payroll_rule_versions where status='active' limit 1")).rows[0].id;
await db.query("insert into spa_payroll_runs(period_start,period_end,rule_version_id,status,created_by) values('2026-10-01','2026-10-31',$1,'finalized',$2)",[rule,owner]);
await reject(()=>call(owner,'spa_attendance_review',[row.id,row.version,false,null,null,0,'撤回']),/PAYROLL_LOCKED/);
await reject(()=>call(owner,'spa_time_entry_save',[null,staff[1].id,'2026-10-06',entry.started_at,entry.ended_at,0,'locked']),/PAYROLL_LOCKED/);
await db.exec("update spa_payroll_runs set status='draft'");
await call(owner,'spa_attendance_review',[row.id,row.version,false,null,null,0,'撤回測試']);
check((await db.query('select status from spa_time_entries where id=$1',[row.time_entry_id])).rows[0].status==='rejected','withdrawal stops salary inclusion and keeps history');
// Location failures and uncertain boundaries remain evidence, not approved pay.
await clock('2026-10-07T10:00:00+08:00');await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute) values($1,'2026-10-07',false,600,1080)",[staff[0].id]);
const exception=await punch(employee,randomUUID(),'in',[null,null,null],'室內定位失敗','permission_denied');
check(exception.flags.includes('location_unavailable')&&exception.flags.includes('no_roster'),'location denial + unrostered shift captured as anomalies');
await clock('2026-10-07T11:00:00+08:00');await punch(employee,randomUUID(),'out',[24,121,8],'臨時外出');
const evidence=(await call(employee,'spa_attendance_self',range)).events;
check(evidence.some(e=>e.flags.includes('outside_store')&&e.distance_m>100),'server computes outside distance');
await call(owner,'spa_attendance_setting_save',[...loc.slice(0,2),200,60,10,1440,settings.address]);
check(evidence.find(e=>e.attendance_id===exception.id).geofence_snapshot.radius_m===100,'changing settings preserves old fence snapshot');
// Overnight clock-in belongs to yesterday's roster, even though today is off.
await clock('2026-10-09T00:30:00+08:00');await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute) values($1,'2026-10-08',true,1200,1560),($1,'2026-10-09',false,600,1080)",[staff[1].id]);
const overnight=await punch(other,randomUUID(),'in',loc);
check(overnight.work_date==='2026-10-08'&&overnight.flags.includes('late'),'overnight session anchored to previous business day');
await clock('2026-10-09T01:00:00+08:00');const nightOut=await punch(other,randomUUID(),'out',loc);
check(nightOut.flags.includes('early_departure'),'early departure compared with snapshotted shift');
// Missing punches can be requested but cannot auto-approve.
const missing=await call(employee,'spa_attendance_request',[randomUUID(),null,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T12:00:00+08:00',0,'忘記打卡']);
await call(owner,'spa_attendance_request_review',[missing,true,'核對門店紀錄']);
check((await call(employee,'spa_attendance_self',range)).rows.some(r=>r.flags.includes('manual_request')&&r.status==='approved'&&!r.clock_in),'approved missing punch keeps honest lack of raw location');
// Dashboard month view uses the final dated roster, current active team, leave,
// actual appointment staff and bed from one permission-checked read model.
const fixture=(await db.query("select (select id from spa_services where active order by display_order limit 1) service,(select id from spa_rooms where active order by name limit 1) room")).rows[0],customer=randomUUID(),appointment=randomUUID();
await db.query("insert into spa_customers(id,name,phone) values($1,'月曆測試客人','0900000001')",[customer]);
await db.query("insert into spa_time_off(staff_id,starts_at,ends_at,reason) values($1,'2026-10-06T13:00:00+08:00','2026-10-06T14:00:00+08:00','教育訓練')",[staff[0].id]);
await db.query("insert into spa_appointments(id,request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents) values($1,$2,$3,$4,$5,$6,'2026-10-06','2026-10-06T10:30:00+08:00','2026-10-06T11:15:00+08:00','2026-10-06T11:30:00+08:00','confirmed','月曆測試療程',110000)",[appointment,randomUUID(),customer,staff[0].id,fixture.room,fixture.service]);
await reject(()=>call(null,'spa_monthly_operations',['2026-10-01']));
const monthView=await call(employee,'spa_monthly_operations',['2026-10-27']),monthDay=monthView.days.find(day=>day.date==='2026-10-06');
check(monthView.from==='2026-10-01'&&monthView.to==='2026-10-31'&&monthView.days.length===31,'monthly operations normalizes and bounds the selected month');
check(monthDay.shifts.some(row=>row.staff_id===staff[0].id&&row.source==='daily'&&row.start_minute===600&&row.end_minute===1080),'monthly operations uses dated roster over weekly template');
check(monthDay.leaves.some(row=>row.staff_id===staff[0].id&&row.reason==='教育訓練')&&monthDay.off_count>=1,'monthly operations shows overlapping leave once in the off count');
check(monthDay.appointments.some(row=>row.id===appointment&&row.staff_id===staff[0].id&&row.room_id===fixture.room&&row.customer_name==='月曆測試客人'),'monthly operations keeps actual staff, customer and bed attribution');
check((await call(owner,'spa_monthly_operations',['2026-02-15'])).days.length===28,'monthly operations handles shorter months');
await db.query("update spa_appointments set status='cancelled' where id=$1",[appointment]);
check(!(await call(owner,'spa_monthly_operations',['2026-10-01'])).days.find(day=>day.date==='2026-10-06').appointments.some(row=>row.id===appointment),'cancelled bookings do not occupy the operations calendar');
await mkdir('work',{recursive:true});await writeFile('work/attendance-qa.json',JSON.stringify({owner,employee,settings,admin:await call(owner,'spa_attendance_admin',range),self:await call(employee,'spa_attendance_self',range),team:await call(owner,'spa_team_os'),catalog:await call(null,'spa_catalog'),profile:await call(employee,'spa_staff_self',range),dashboard:await call(owner,'spa_dashboard'),employeeSession:await call(employee,'spa_session'),ownerSession:await call(owner,'spa_session')}));
await db.query("update spa_staff set active=false,employment_status='inactive' where id=$1",[staff[0].id]);await reject(()=>call(employee,'spa_attendance_self',range),/FORBIDDEN|STAFF_NOT_ACTIVE/);
check(attendanceMinutes({effective_start:'2026-10-06T10:00:00Z',effective_end:'2026-10-06T11:00:35Z',break_minutes:10})===50,'UI net minutes use same rounding');
check(taipeiInput('2026-10-06T16:15:00Z')==='2026-10-07T00:15'&&attendanceStamp('2026-10-07T00:15')==='2026-10-07T00:15:00+08:00','client conversion independent of host timezone');
check(attendanceStamp('2026-10-07T00:15','2026-10-06T16:15:59.500Z')==='2026-10-06T16:15:59.500Z','unchanged review fields preserve original seconds');
check((await db.query("select count(*)::int n from spa_audit where action like 'attendance.%'")).rows[0]?.n>0,'attendance changes have audit history');
console.log(`Attendance checks passed: ${checks}`);await db.close();
