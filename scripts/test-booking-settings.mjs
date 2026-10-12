import { PGlite } from '@electric-sql/pglite';
import { readFile,readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
process.on('uncaughtException',error=>{console.error(error.message);process.exit(1);});
const db=new PGlite();let checks=0;
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
 create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of (await readdir(directory)).filter(file=>file.endsWith('.sql')).sort())await db.exec(await readFile(new URL(file,directory),'utf8'));
const owner=randomUUID(),employee=randomUUID();
await db.query('insert into auth.users(id) values($1),($2)',[owner,employee]);
const staff=(await db.query('select id from spa_staff where active limit 1')).rows[0].id;
await db.query("insert into spa_roles(user_id,role,staff_id) values($1,'owner',null),($2,'therapist',$3)",[owner,employee,staff]);
async function save(user,args){await db.exec('begin');try{await db.exec('set local role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user,JSON.stringify({iat:Math.floor(Date.now()/1000)+1})]);await db.query('select public.spa_booking_policy_save($1,$2,$3,$4,$5,$6,$7)',args);await db.exec('commit');}catch(e){await db.exec('rollback');throw e;}}
const read=async()=>(await db.query('select opening_minute,closing_minute,booking_days,auto_confirm,cancellation_hours,max_staff_off_per_day,simultaneous_capacity from spa_settings')).rows[0];
const before=await read();
for(const args of [[600,1320,60,false,12,2,0],[600,1320,60,false,12,21,4],[600,1320,181,false,12,2,4],[600,1320,60,null,12,2,4]]){
 await assert.rejects(()=>save(owner,args),/INVALID_INPUT/);checks++;
 assert.deepEqual(await read(),before,'invalid field leaves all booking/roster/capacity settings unchanged');checks++;
}
await assert.rejects(()=>save(employee,[600,1320,60,false,12,2,4]),/FORBIDDEN/);checks++;
await save(owner,[660,1500,60,false,12,1,5]);
assert.deepEqual(await read(),{opening_minute:660,closing_minute:1500,booking_days:60,auto_confirm:false,cancellation_hours:12,max_staff_off_per_day:1,simultaneous_capacity:5});checks++;
await db.close();console.log(`Atomic booking settings checks passed: ${checks}`);
