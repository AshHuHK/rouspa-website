import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
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
create table public.ai_limit_test_clock(instant timestamptz not null);
insert into public.ai_limit_test_clock values('2026-10-08T10:20:10.25+08:00');
create function public.ai_limit_test_now() returns timestamptz language sql stable security definer set search_path='' as $$select instant from public.ai_limit_test_clock$$;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of(await readdir(directory)).filter(file=>file.endsWith('.sql')).sort())await db.exec((await readFile(new URL(file,directory),'utf8')).replaceAll('now()','public.ai_limit_test_now()').replaceAll('clock_timestamp()','public.ai_limit_test_now()'));
const owner=randomUUID(),employee=randomUUID(),custom=randomUUID(),outsider=randomUUID();
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6),($7,$8)',[owner,'owner@ai.test',employee,'employee@ai.test',custom,'custom@ai.test',outsider,'outsider@ai.test']);
const staff=(await db.query("select * from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',null,null),($2,'therapist',$3,'ai_employee')",[owner,employee,staff[0].id]);
async function as(user,sql,args=[],role=user?'authenticated':'anon',iat=2000000000){
 await db.exec('begin');try{
  await db.exec(`set local role ${role}`);
  await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat})]);
  const result=await db.query(sql,args);await db.exec('commit');return result.rows;
 }catch(error){await db.exec('rollback');throw error;}
}
async function reserve(user,role,iat){return(await as(user,'select public.spa_ai_reserve_request() result',[],role,iat))[0].result;}
async function clock(instant){await db.query('update public.ai_limit_test_clock set instant=$1',[instant]);}
const usage=async user=>(await db.query('select user_id,usage_day::text,day_requests,minute_start,minute_requests,updated_at from spa_private.ai_steward_usage where user_id=$1',[user])).rows[0];
const admin=async(name,args=[])=>(await as(owner,`select public.${name}(${args.map((_,index)=>'$'+(index+1)).join(',')}) result`,args))[0].result;

await reject(()=>reserve(null),/permission denied/);
await reject(()=>reserve(owner,'anon'),/permission denied/);
await reject(()=>reserve(null,'authenticated'),/FORBIDDEN/);
await reject(()=>reserve(null,'service_role'),/FORBIDDEN/);
await reject(()=>reserve(outsider),/FORBIDDEN/);
check((await db.query('select count(*) n from spa_private.ai_steward_usage')).rows[0].n===0,'anonymous and invalid identities never create counters');
await reject(()=>as(employee,'select * from spa_private.ai_steward_usage'),/permission denied/);
await reject(()=>as(owner,'select * from spa_private.ai_steward_usage'),/permission denied/);
await reject(()=>as(owner,"update spa_private.ai_steward_usage set day_requests=0"),/permission denied/);
await reject(()=>as(owner,'select public.spa_ai_reserve_request($1)',[employee]),/does not exist/);
const columns=(await db.query("select column_name from information_schema.columns where table_schema='spa_private' and table_name='ai_steward_usage' order by ordinal_position")).rows.map(row=>row.column_name);
check(JSON.stringify(columns)===JSON.stringify(['user_id','usage_day','day_requests','minute_start','minute_requests','updated_at']),'private storage contains only identity and counters, with no question or answer');
const definition=(await db.query("select p.prosecdef,p.proconfig,p.pronargs from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='spa_ai_reserve_request'")).rows[0];
check(definition.prosecdef&&definition.pronargs===0&&definition.proconfig.includes('search_path=""'),'reservation is a zero-argument security definer with an empty search path');
const privileges=(await db.query("select has_function_privilege('anon','public.spa_ai_reserve_request()','execute') anonymous,has_function_privilege('authenticated','public.spa_ai_reserve_request()','execute') authenticated,has_function_privilege('service_role','public.spa_ai_reserve_request()','execute') service")).rows[0];
check(!privileges.anonymous&&privileges.authenticated&&privileges.service,'only authenticated and service roles have execution grants');
let result=await reserve(owner);
check(result.allowed&&result.reason===null&&result.retry_after===0&&result.remaining===99,'owner receives 100 daily reservations with explicit success fields');
check((await reserve(owner)).remaining===98&&(await reserve(owner)).remaining===97,'three reservations are accepted in one fixed server minute');
result=await reserve(owner);
check(!result.allowed&&result.reason==='minute_limit'&&result.retry_after===50&&result.remaining===97,'fourth minute request returns a normal denial and rounds retry seconds up');
check((await usage(owner)).day_requests===3&&(await usage(owner)).minute_requests===3,'minute rejection commits normally without consuming a fourth reservation');
check(!(await reserve(owner)).allowed&&(await usage(owner)).day_requests===3,'retrying a denied reservation does not roll back or reset earlier usage');
result=await reserve(employee);
check(result.allowed&&result.remaining===39,'employee has a separate 40/day budget unaffected by owner usage');
check((await reserve(employee,'service_role')).remaining===38,'service-role execution still binds the quota to the authenticated team identity');
await clock('2026-10-08T10:21:00+08:00');
check((await reserve(owner)).remaining===96&&(await usage(owner)).minute_requests===1,'minute rollover resets minute usage while retaining daily usage');

// Each account consumes its entire daily budget across distinct server minutes.
await db.query('delete from spa_private.ai_steward_usage');
for(let index=0;index<100;index++){
 await clock(`2026-10-08T11:${String(Math.floor(index/3)).padStart(2,'0')}:00+08:00`);
 result=await reserve(owner);assert.equal(result.allowed,true);assert.equal(result.remaining,99-index);
}
checks++;
await clock('2026-10-08T12:00:00+08:00');
result=await reserve(owner);
check(!result.allowed&&result.reason==='daily_limit'&&result.remaining===0&&result.retry_after===43200,'owner reservation 101 is denied until the next Taipei midnight');
check((await usage(owner)).day_requests===100&&(await usage(owner)).minute_requests===0,'daily denial preserves consumption and commits the new minute window');
for(let index=0;index<40;index++){
 await clock(`2026-10-08T12:${String(Math.floor(index/3)).padStart(2,'0')}:00+08:00`);
 result=await reserve(employee);assert.equal(result.allowed,true);assert.equal(result.remaining,39-index);
}
checks++;
await clock('2026-10-08T13:00:00+08:00');
result=await reserve(employee);
check(!result.allowed&&result.reason==='daily_limit'&&result.remaining===0&&(await usage(employee)).day_requests===40,'employee reservation 41 is denied independently of owner consumption');
await clock('2026-10-08T15:59:59.25Z');
result=await reserve(owner);
check(!result.allowed&&result.retry_after===1,'daily retry rounds the final fraction of a second to one');
await clock('2026-10-08T16:00:00Z');
result=await reserve(owner);
check(result.allowed&&result.remaining===99&&(await usage(owner)).usage_day==='2026-10-09','UTC 16:00 rolls daily counters to the next Taipei date');
check((await usage(owner)).day_requests===1&&(await usage(owner)).minute_requests===1,'day rollover starts fresh daily and minute windows');
check((await reserve(employee)).remaining===39,'employee daily budget also refreshes at server Taipei midnight');
await clock('2026-10-09T00:00:00Z');
check((await reserve(owner)).remaining===98&&(await usage(owner)).usage_day==='2026-10-09','UTC midnight does not reset the already-started Taipei day');
await clock('2026-10-09T00:01:00Z');
const batch=await as(owner,'select public.spa_ai_reserve_request() result from generate_series(1,4)');
check(batch.slice(0,3).every(row=>row.result.allowed)&&batch[3].result.reason==='minute_limit','multiple reservations in one transaction share the same locked quota row');
check((await usage(owner)).day_requests===5&&(await usage(owner)).minute_requests===3,'normal denial lets the transaction commit its three earlier reservations');

// Validity is checked on every request, rather than relying on a UI role label.
await admin('spa_role_profile_save',['ai_assistant','AI 助理',['dashboard.view','appointments.view','reviews.view'],true,50]);
await admin('spa_staff_account_link',[staff[1].id,custom,'ai_assistant',true,false,'ai_custom']);
check((await reserve(custom)).remaining===39,'owner-created non-owner role receives the 40/day employee allowance');
await db.query('update spa_roles set active=false where user_id=$1',[employee]);
await reject(()=>reserve(employee),/FORBIDDEN/);
await db.query('update spa_roles set active=true,login_after=$2 where user_id=$1',[employee,'2026-10-09T09:00:00+08:00']);
await reject(()=>reserve(employee,'authenticated',1),/FORBIDDEN/);
check((await reserve(employee,'authenticated',2000000000)).allowed,'fresh JWT can reserve after account-session revocation');
await admin('spa_role_profile_save',['ai_assistant','AI 助理',[],false,50]);
await reject(()=>reserve(custom),/FORBIDDEN/);
await admin('spa_role_profile_save',['ai_assistant','AI 助理',[],true,50]);
for(const change of ["active=false","employment_status='departed',departed_on='2026-10-09',departure_reason='quota fixture'","archived_at=public.ai_limit_test_now()"]){
 await db.query(`update spa_staff set ${change} where id=$1`,[staff[1].id]);
 await reject(()=>reserve(custom),/FORBIDDEN/);
 await db.query("update spa_staff set active=true,employment_status='active',departed_on=null,departure_reason='',archived_at=null where id=$1",[staff[1].id]);
}
check((await usage(custom)).day_requests===1,'rejected inactive personnel and roles do not consume reservations');
await db.query('delete from auth.users where id=$1',[outsider]);
check(!(await usage(outsider)),'unused outsider identity leaves no reservation evidence');
await db.close();console.log(`AI steward quota checks passed: ${checks}`);
