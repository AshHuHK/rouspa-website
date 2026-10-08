import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
process.on('uncaughtException',error=>{console.error(error.message);if(error.where)console.error(error.where);process.exit(1);});

const db=new PGlite();let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const reject=async(fn,pattern)=>{await assert.rejects(fn,pattern);checks++;};
await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
create table public.convenience_test_clock(instant timestamptz not null);
insert into public.convenience_test_clock values('2026-10-09T00:30:00+08:00');
create schema spa_private;
create function spa_private.convenience_test_now() returns timestamptz language sql stable security definer set search_path='' as $$select instant from public.convenience_test_clock$$;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).filter(file=>file.endsWith('.sql')).sort()){
 let source=await readFile(new URL(file,directory),'utf8');
 if(file==='202610080006_operations_convenience.sql')source=source.replaceAll('now()','spa_private.convenience_test_now()');
 await db.exec(source);
}
await db.exec(`create or replace function spa_private.public_booking_last_date() returns date language sql stable security definer set search_path='' as $$
 select (date_trunc('month',(spa_private.convenience_test_now() at time zone 'Asia/Taipei')::date)+interval '2 months - 1 day')::date$$;`);
const owner=randomUUID(),employee=randomUUID(),outsider=randomUUID();
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)',[owner,'owner@convenience.test',employee,'staff@convenience.test',outsider,'outsider@convenience.test']);
const people=(await db.query("select * from spa_staff where active and employment_status='active' and archived_at is null order by display_order limit 4")).rows;
check(people.length===4,'fixture has four active therapists');
await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',null,null),($2,'therapist',$3,'convenience_staff')",[owner,employee,people[0].id]);
const rooms=(await db.query('select * from spa_rooms where active order by name')).rows;
const service=(await db.query("select * from spa_services where active and online_booking_enabled order by display_order limit 1")).rows[0];
const product=(await db.query("select * from spa_products where status='active' order by display_order limit 1")).rows[0];
const customer=(await db.query("insert into spa_customers(name,phone,customer_type,status) values('測試客人','0991888001','member','active') returning id")).rows[0].id;
async function call(user,role=user?'authenticated':'anon'){
 await db.exec('begin');try{
  await db.exec(`set local role ${role}`);
  await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat:Math.floor(Date.now()/1000)+60})]);
  const response=(await db.query('select public.spa_operations_convenience() result')).rows[0].result;await db.exec('commit');return response;
 }catch(error){await db.exec('rollback');throw error;}
}
async function appointment(index,person,start,end,blocked,status='confirmed',day='2026-10-08'){
 return (await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,note)
 values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'不應提供給員工的備註') returning *`,[randomUUID(),customer,person,rooms[index].id,service.id,day,start,end,blocked,status,service.name,service.price_cents])).rows[0];
}
const treatment=await appointment(0,people[0].id,'2026-10-08T23:50:00+08:00','2026-10-09T00:45:00+08:00','2026-10-09T01:00:00+08:00','checked_in');
const buffer=await appointment(1,people[1].id,'2026-10-08T23:35:00+08:00','2026-10-09T00:20:00+08:00','2026-10-09T00:45:00+08:00','completed');
const reserved=await appointment(2,people[2].id,'2026-10-09T00:40:00+08:00','2026-10-09T01:25:00+08:00','2026-10-09T01:40:00+08:00');
const cancelled=await appointment(3,people[3].id,'2026-10-08T23:40:00+08:00','2026-10-09T00:25:00+08:00','2026-10-09T00:40:00+08:00','cancelled');
const next=await appointment(3,people[3].id,'2026-10-09T02:00:00+08:00','2026-10-09T02:45:00+08:00','2026-10-09T03:00:00+08:00','confirmed','2026-10-09');
await appointment(0,people[0].id,'2026-11-02T10:00:00+08:00','2026-11-02T10:45:00+08:00','2026-11-02T11:00:00+08:00','pending','2026-11-02');
await appointment(0,people[0].id,'2026-06-02T10:00:00+08:00','2026-06-02T10:45:00+08:00','2026-06-02T11:00:00+08:00','pending','2026-06-02');
await appointment(0,people[0].id,'2026-10-07T10:00:00+08:00','2026-10-07T10:45:00+08:00','2026-10-07T11:00:00+08:00','confirmed','2026-10-07');
await db.query(`insert into spa_attendance(staff_id,work_date,clock_in,clock_out,status) values
 ($1,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T18:00:00+08:00','pending'),
 ($2,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T18:00:00+08:00','pending'),
 ($1,'2026-10-07','2026-10-07T00:00:00+08:00',null,'open')`,[people[0].id,people[1].id]);
await db.query(`insert into spa_attendance_requests(request_id,staff_id,work_date,proposed_start,proposed_end,break_minutes,reason,created_by) values($1,$2,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T18:00:00+08:00',0,'漏打卡核對',$3)`,[randomUUID(),people[0].id,employee]);
await db.query(`insert into spa_staff_schedule_change_requests(staff_id,business_date,desired_working,desired_start_minute,desired_end_minute,reason,requested_by,requested_at) values($1,'2026-11-12',false,600,1320,'需要調整休假',$2,'2026-10-08T10:00:00+08:00')`,[people[0].id,employee]);
await db.query(`insert into spa_payroll_runs(period_start,period_end,rule_version_id,created_by,needs_recalculation)
 select '2026-10-01','2026-10-31',id,$1,true from spa_payroll_rule_versions where status='active' order by version_no desc limit 1`,[owner]);
const inventory=Number((await db.query('select coalesce(sum(delta),0) n from spa_inventory_entries where product_id=$1',[product.id])).rows[0].n);
if(inventory!==1)await db.query("insert into spa_inventory_entries(product_id,delta,reason) values($1,$2,'測試庫存')",[product.id,1-inventory]);
await db.query("insert into spa_reviews(appointment_id,rating,comment,created_at) values($1,5,'舒適的服務','2026-10-08T12:00:00+08:00')",[buffer.id]);

const count=response=>Object.fromEntries(response.todos.map(task=>[task.key,task.count]));
const bed=(response,index)=>response.beds.find(item=>item.id===rooms[index].id);
await reject(()=>call(null),/permission denied|FORBIDDEN/);
await reject(()=>call(outsider),/FORBIDDEN/);
let admin=await call(owner),staff=await call(employee);
check(admin.today==='2026-10-09'&&admin.target_month==='2026-11-01'&&!admin.edit_open,'Taiwan date drives overnight date and day-eight lock');
check(admin.window.from==='2026-07-11'&&admin.window.to==='2026-11-30','todo query window is bounded to 90 days back and next month end');
check(admin.beds.length===4,'board derives the four enabled store beds');
check(bed(admin,0).state==='treatment'&&bed(admin,0).current.business_date==='2026-10-08','overnight checked-in treatment remains assigned to its original business date');
check(bed(admin,1).state==='buffer','completed service retains its existing blocked buffer');
check(bed(admin,2).state==='reserved'&&bed(admin,2).current===null&&bed(admin,2).next.id===reserved.id,'near-future reservation is visible before start');
check(bed(admin,3).state==='free'&&bed(admin,3).next.id===next.id,'cancelled appointment never occupies bed; next future booking remains visible');
check(admin.beds.every(item=>item.overlap_count<=1),'bed board preserves database non-overlap allocation');
check(bed(admin,0).current.customer_name==='測試客人'&&bed(staff,0).current.customer_name==='測客人','staff response is gender-neutral surname only while owner retains full identity');
check(!JSON.stringify(staff).includes('0991888001')&&!JSON.stringify(staff).includes('不應提供給員工')&&!JSON.stringify(staff).includes('manage_token')&&!JSON.stringify(staff).includes('price_cents'),'staff board exposes no customer phone, private notes, access tokens or finances');
check(bed(staff,0).current.is_own===true&&bed(staff,1).current.is_own===false,'own service highlight maps to actual assigned technician');
check(!staff.is_owner&&staff.todos.every(item=>item.key.startsWith('my_')&&['self','bookings'].includes(item.module)),'staff receives only own permitted reminders');
check(count(admin).pending_bookings===1,'pending booking count excludes history outside destination window');
check(count(admin).arrivals===2&&count(admin).unsettled===1,'near arrival, overdue unarrived booking and completed unsettled count derive actual appointment state');
check(count(admin).attendance===2&&count(staff).my_attendance===1,'owner sees both pending attendances; staff sees only their own');
check(count(admin).corrections===1&&count(admin).missing_clockout===1&&count(staff).my_clockout===1,'attendance corrections and overdue open shift drive correct reminders');
check(count(admin).schedule_requests===1&&count(admin).missing_schedule===1&&count(staff).my_requests===1&&count(staff).my_submission===1,'pending schedule requests and unsubmitted target month are shared source data');
check(count(admin).payroll_drafts===1&&count(admin).low_stock>=1&&count(admin).reviews===1,'stale payroll, low inventory and pending reviews are owner-only actionable todos');
check(count(staff).my_schedule===1,'staff service reminder uses assigned technician and bounded near-future window');
check(new Date(admin.todos.find(item=>item.key==='arrivals').context.starts_before).valueOf()===new Date('2026-10-09T01:00:00+08:00').valueOf(),'arrival destination carries exact server cutoff');
check(admin.todos.find(item=>item.key==='completion').context.statuses.includes('in_service'),'completion navigation includes every status counted');
check(admin.todos.find(item=>item.key==='attendance').context.section==='attendance-review'&&staff.todos.find(item=>item.key==='my_requests').context.section==='my-schedule','todo destinations use owner and employee specific existing sections');
check(admin.todos.filter(item=>!['low_stock'].includes(item.key)).every(item=>item.context.from&&item.context.to),'date-dependent todos carry the same bounded destination range');

const before=(await db.query(`select (select count(*) from spa_appointments) bookings,(select count(*) from spa_attendance) attendance,(select count(*) from spa_audit) audit,(select count(*) from spa_orders) orders`)).rows[0];
await call(owner);await call(employee);
check(JSON.stringify(before)===JSON.stringify((await db.query(`select (select count(*) from spa_appointments) bookings,(select count(*) from spa_attendance) attendance,(select count(*) from spa_audit) audit,(select count(*) from spa_orders) orders`)).rows[0]),'refresh is read-only and never changes allocation, attendance, orders or audit');
await db.query("update convenience_test_clock set instant='2026-10-09T00:45:00+08:00'");admin=await call(owner);
check(bed(admin,0).state==='buffer'&&bed(admin,1).state==='free','exact treatment end starts buffer; exact blocked-until boundary releases bed');
check(bed(admin,2).state==='reserved','elapsed clock alone never claims a confirmed customer has arrived');
await db.query("update spa_appointments set status='checked_in' where id=$1",[reserved.id]);
check(bed(await call(owner),2).state==='treatment','owner check-in is reflected immediately on the bed board');
await db.query("update spa_appointments set status='completed' where id=$1",[reserved.id]);
check(bed(await call(owner),2).state==='buffer','early completion shows buffer without changing reservation capacity interval');
await db.query('update spa_appointments set staff_id=$1 where id=$2',[people[3].id,treatment.id]);
check(bed(await call(employee),0).current.is_own===false,'reassignment removes original technician own-service highlight');
await db.query("insert into spa_staff_schedule_submissions(staff_id,schedule_month,submitted_by) values($1,'2026-11-01',$2)",[people[0].id,employee]);
staff=await call(employee);
check(!staff.todos.some(item=>item.key==='my_submission')&&count(await call(owner)).missing_schedule===0,'completed schedule submission clears both employee and owner reminders');
await db.query("update spa_attendance set status='approved' where status='pending'");
check(count(await call(owner)).attendance===0&&count(await call(employee)).my_attendance===0,'attendance approval clears reminders without a separate synchronization copy');
await db.query("update spa_roles set active=false where user_id=$1",[employee]);
await reject(()=>call(employee),/FORBIDDEN/);
await db.query("update spa_roles set active=true where user_id=$1",[employee]);
await db.query("update spa_staff set employment_status='departed',active=false,departed_on='2026-10-08',departure_reason='測試離職' where id=$1",[people[0].id]);
await reject(()=>call(employee),/FORBIDDEN/);
await db.query("update spa_staff set employment_status='active',active=true,departed_on=null,departure_reason='' where id=$1",[people[0].id]);
await db.query("update convenience_test_clock set instant='2026-10-07T23:59:59+08:00'");
check((await call(employee)).edit_open,'server Taiwan day-seven schedule window remains open');
await db.query("update convenience_test_clock set instant='2026-10-08T00:00:00+08:00'");
check(!(await call(employee)).edit_open,'server Taiwan midnight on day eight closes self scheduling');
await db.query('update spa_rooms set active=false where id=$1',[rooms[3].id]);
check((await call(owner)).beds.length===3,'disabling an existing resource automatically removes it from live board');
await db.query('update spa_rooms set active=true where id=$1',[rooms[3].id]);
await db.query("update convenience_test_clock set instant='2026-10-09T00:30:00+08:00'");
if(process.env.CONVENIENCE_QA_FILE)await writeFile(process.env.CONVENIENCE_QA_FILE,JSON.stringify({owner:await call(owner),employee:await call(employee)},null,2));
await db.close();console.log(`Operations convenience checks passed: ${checks}`);
