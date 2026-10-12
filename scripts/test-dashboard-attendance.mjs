import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { summarizeDashboardAttendance } from '../src/lib/dashboard-attendance.js';

const db=new PGlite();let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
await db.exec(`create role anon;create role authenticated;create role service_role;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).filter(file=>file.endsWith('.sql')).sort())await db.exec(await readFile(new URL(file,directory),'utf8'));

const owner=randomUUID(),employee=randomUUID();
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)',[owner,'attendance-dashboard-owner@example.test',employee,'attendance-dashboard-staff@example.test']);
await db.query("insert into spa_roles(user_id,role,active) values($1,'owner',true)",[owner]);
async function call(user,name){await db.exec('begin');try{await db.exec('set local role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user,JSON.stringify({iat:Math.floor(Date.now()/1000)})]);const value=(await db.query(`select public.${name}() result`)).rows[0].result;await db.exec('commit');return value;}catch(error){await db.exec('rollback');throw error;}}

const today=(await db.query("select (now() at time zone 'Asia/Taipei')::date::text value")).rows[0].value;
const currentMinute=Number((await db.query("select extract(hour from now() at time zone 'Asia/Taipei')::int*60+extract(minute from now() at time zone 'Asia/Taipei')::int value")).rows[0].value);
const staff=(await db.query("select id from spa_staff where active and employment_status='active' and archived_at is null order by display_order,id limit 5")).rows;
assert.equal(staff.length,5,'fixture needs five active staff');
await db.query(`insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note,updated_by)
 select id,$1,false,0,60,'出勤總覽測試',$2 from spa_staff where active and employment_status='active' and archived_at is null
 on conflict(staff_id,business_date) do update set is_working=false,start_minute=0,end_minute=60,note='出勤總覽測試',updated_by=excluded.updated_by`,[today,owner]);
const currentStart=Math.max(0,currentMinute-60),currentEnd=currentMinute+120,upcomingStart=currentMinute+60;
for(const [index,row] of staff.entries())await db.query(`update spa_daily_shifts set is_working=true,start_minute=$3,end_minute=$4 where staff_id=$1 and business_date=$2`,[row.id,today,index===4?upcomingStart:currentStart,index===4?upcomingStart+60:currentEnd]);
await db.query('update spa_attendance_settings set grace_minutes=0 where id');
await db.query(`insert into spa_attendance(staff_id,work_date,clock_in,effective_start,status) values($1,$2,now()-interval '30 minutes',now()-interval '30 minutes','open')`,[staff[0].id,today]);
await db.query(`insert into spa_attendance(staff_id,work_date,clock_in,clock_out,effective_start,effective_end,status) values($1,$2,now()-interval '90 minutes',now()-interval '10 minutes',now()-interval '90 minutes',now()-interval '10 minutes','pending')`,[staff[1].id,today]);
await db.query(`insert into spa_time_off(staff_id,starts_at,ends_at,reason) values($1,now()-interval '1 hour',now()+interval '1 hour','核准休假')`,[staff[3].id]);
await db.query("insert into spa_roles(user_id,role,staff_id,active) values($1,'therapist',$2,true)",[employee,staff[0].id]);

const dashboard=await call(owner,'spa_dashboard'),packet=dashboard.attendance_today;
check(packet&&packet.staff.length===5,'owner dashboard returns exactly the five scheduled active staff');
check(packet.staff.every(row=>!('latitude' in row)&&!('longitude' in row)&&!('distance_m' in row)),'dashboard never exposes punch location evidence');
const summary=summarizeDashboardAttendance(packet,Date.parse(packet.server_time));
check(summary.scheduled===5&&summary.arrived===2&&summary.working===1&&summary.completed===1,'scheduled, arrived, working and completed counts use punch facts');
check(summary.late===1&&summary.onLeave===1&&summary.upcoming===1&&summary.absent===0,'late, leave and upcoming states follow roster time and leave');
check((await call(employee,'spa_dashboard')).attendance_today===null,'non-owner dashboard cannot read team attendance detail');
check(summary.staff.find(row=>row.display_status==='late').staff_id===staff[2].id,'the missing scheduled employee is identified without guessing');

await db.close();
console.log(`PASS: ${checks} owner dashboard attendance assertions`);
