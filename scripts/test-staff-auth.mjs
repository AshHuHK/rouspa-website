import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
let assertions=0;const check=(ok,label)=>{assert.ok(ok,label);assertions++;};
async function load(file){const source=(await readFile(new URL('../supabase/functions/'+file+'/index.ts',import.meta.url),'utf8')).replace(/^import .*\n/,'');return import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));}
const {createStaffHandler}=await load('staff-accounts'),{createLoginHandler}=await load('staff-login');
const owner=randomUUID(),user=randomUUID(),person=randomUUID();
const environment=k=>({SUPABASE_URL:'https://example.test',SUPABASE_ANON_KEY:'public-key',SUPABASE_SERVICE_ROLE_KEY:'server-secret'}[k]);
function fixture(opts={}){
 const events=[];
 const caller={auth:{getUser:async()=>({data:{user:opts.invalidToken?null:{id:owner}},error:null})},rpc:async(name,args)=>{
  events.push({name,args});
  if(name==='spa_session')return {data:{role:opts.role||'owner'}};
  if(name==='spa_staff_account_target')return {data:{archived:!!opts.archived,account:opts.account===false?null:{user_id:user,role:'therapist',active:true,username:'rou_staff',email:'internal@staff.rouspa.invalid',...opts.account}}};
  if(name==='spa_staff_account_link')return opts.linkError?{error:{message:opts.linkError}}:{data:null};
  if(name==='spa_staff_archive')return opts.archiveError?{error:{message:opts.archiveError}}:{data:null};
 }};
 const admin={auth:{admin:{
  createUser:async args=>{events.push({name:'auth.create',args});return opts.createError?{error:{}}:{data:{user:{id:user}}};},
  updateUserById:async(id,args)=>{events.push({name:'auth.update',id,args});return opts.updateError?{error:{}}:{data:{user:{id}}};},
  deleteUser:async id=>{events.push({name:'auth.delete',id});return opts.cleanupError?{error:{}}:{data:{}};}
 }}};
 const clientFactory=(_url,key)=>{events.push({name:'client',key});return key==='server-secret'?admin:caller;};
 return {handler:createStaffHandler({clientFactory,environment}),events};
}
const payload={action:'create',staff_id:person,username:'Rou_Staff',password:'test-password-only',role:'therapist'};
const request=(body,options={})=>new Request('https://example.test/functions/v1/staff-accounts',{method:'POST',headers:{authorization:'Bearer test-session',origin:'https://www.rouspa.tw','content-type':'application/json',...options.headers},body:typeof body==='string'?body:JSON.stringify(body)});
let f=fixture(),r=await f.handler(request(payload,{headers:{authorization:''}}));check(r.status===401&&f.events.length===0,'missing session never reaches privileged client');
f=fixture({invalidToken:true});r=await f.handler(request(payload));check(r.status===401&&!f.events.some(e=>e.key==='server-secret'),'invalid JWT rejected before privilege');
for(const role of ['therapist','manager','receptionist','customer']){f=fixture({role});r=await f.handler(request(payload));check(r.status===403&&!f.events.some(e=>e.key==='server-secret'),'only owner can administer accounts');}
f=fixture();r=await f.handler(request(payload,{headers:{origin:'https://evil.test'}}));check(r.status===403&&f.events.length===0,'unknown origin rejected');
for(const body of [{...payload,role:'owner'},{...payload,staff_id:'not-a-uuid'},{...payload,username:'xx'},{...payload,password:'short'},'not json']){f=fixture({account:false});r=await f.handler(request(body));check(r.status===400&&!f.events.some(e=>e.key==='server-secret'),'bad inputs cannot reach Auth Admin');}
f=fixture();r=await f.handler(request(payload));check(r.status===409&&!f.events.some(e=>e.name==='auth.create'),'duplicate create is not replayed');
f=fixture({account:false});r=await f.handler(request(payload));const created=await r.json();check(r.status===200&&created.username==='rou_staff'&&!('password' in created)&&!('email' in created),'create response contains username only');
check(f.events.find(e=>e.name==='auth.create').args.email===`${person}@staff.rouspa.invalid`,'internal Auth alias requires no real staff mailbox');
check(f.events.find(e=>e.name==='auth.create').args.email_confirm===true,'no verification email needed');
check(f.events.find(e=>e.name==='spa_staff_account_link').args.p_username==='rou_staff','username and staff account bind atomically');
f=fixture({account:false,linkError:'USERNAME_TAKEN'});r=await f.handler(request(payload));check((await r.json()).error==='USERNAME_TAKEN'&&f.events.find(e=>e.name==='auth.delete')?.id===user,'failed username binding deletes only newly created Auth user');
f=fixture({account:false,linkError:'ACCOUNT_CONFLICT',cleanupError:true});r=await f.handler(request(payload));check((await r.json()).error==='ACCOUNT_LINK_CLEANUP_REQUIRED','cleanup failure surfaced honestly');
f=fixture({account:{user_id:owner}});r=await f.handler(request({...payload,action:'password'}));check(r.status===403&&!f.events.some(e=>e.key==='server-secret'),'cannot reset own owner password through staff form');
f=fixture({account:{role:'owner'}});r=await f.handler(request({...payload,action:'password'}));check(r.status===403,'owner role protected');
f=fixture();r=await f.handler(request({...payload,action:'password'}));check(r.status===200,'reset linked staff password');
check(f.events.findIndex(e=>e.name==='spa_staff_account_link')<f.events.findIndex(e=>e.name==='auth.update'),'old backend sessions revoked before password reset');
check(f.events.find(e=>e.name==='spa_staff_account_link').args.p_reset===true,'password reset invalidates old JWT issue times');
f=fixture({linkError:'FORBIDDEN'});r=await f.handler(request({...payload,action:'password'}));check(r.status===409&&!f.events.some(e=>e.name==='auth.update'),'failed authorization never changes Auth password');
f=fixture({updateError:true});r=await f.handler(request({...payload,action:'password'}));check((await r.json()).error==='PASSWORD_RESET_FAILED','Auth password failure reported');
f=fixture();r=await f.handler(request({...payload,action:'username',username:'rou_new'}));check(r.status===200&&f.events.find(e=>e.name==='spa_staff_account_link').args.p_username==='rou_new'&&!f.events.some(e=>e.name==='auth.update'),'rename username without touching mailbox');
f=fixture();r=await f.handler(request({...payload,action:'access',active:false}));check(r.status===200&&f.events.find(e=>e.name==='auth.update').args.ban_duration==='876000h','disabled staff cannot log in');
f=fixture({updateError:true});r=await f.handler(request({...payload,action:'access',active:false}));const partial=await r.json();check(partial.error==='ACCOUNT_AUTH_SYNC_REQUIRED'&&partial.access_saved,'partial Auth sync failure retains DB access revocation');
f=fixture({archiveError:'EXISTING_BOOKINGS'});r=await f.handler(request({...payload,action:'archive',reason:'離職'}));check((await r.json()).error==='EXISTING_BOOKINGS'&&!f.events.some(e=>e.name==='auth.update'),'cannot archive unresolved future bookings');
f=fixture({account:false});r=await f.handler(request({...payload,action:'archive',reason:'離職'}));check(r.status===200&&!f.events.some(e=>e.name==='auth.update'),'person without account can be archived');
f=fixture({archived:true});r=await f.handler(request({...payload,action:'restore',reason:'復職'}));check(r.status===200&&f.events.find(e=>e.name==='auth.update').args.ban_duration==='876000h','restore does not silently re-enable login');
function loginFixture(opts={}){
 const events=[];const clientFactory=(_url,key)=>key==='server-secret'?{rpc:async(name,args)=>{events.push({name,args});return {data:opts.unknown?null:opts.limited?{limited:true}:{email:'synthetic@staff.rouspa.invalid',user_id:user}};}}:{auth:{signInWithPassword:async args=>{events.push({name:'auth.signin',args});return {error:opts.wrong?{}:null,data:{user:{id:opts.wrongIdentity?owner:user},session:{access_token:'test-access',refresh_token:'test-refresh'}}};}}};
 return {handler:createLoginHandler({clientFactory,environment}),events};
}
let l=loginFixture();r=await l.handler(request({username:' ROU_STAFF ',password:'test-password-only'}));check(r.status===200&&(await r.json()).access_token==='test-access','username/password login returns standard session');
check(l.events[0].args.p_username==='rou_staff','username normalization');
check(l.events[1].args.email==='synthetic@staff.rouspa.invalid','password verified by Supabase Auth');
for(const opts of [{wrong:true},{unknown:true},{wrongIdentity:true}]){l=loginFixture(opts);r=await l.handler(request({username:'rou_staff',password:'wrong'}));check(r.status===401&&(await r.json()).error==='INVALID_LOGIN','unknown, disabled and wrong passwords do not reveal identity');}
l=loginFixture({limited:true});r=await l.handler(request({username:'rou_staff',password:'wrong'}));check(r.status===429&&!l.events.some(e=>e.name==='auth.signin'),'rate limit stops Auth calls');
l=loginFixture();r=await l.handler(request({username:'x',password:'test'}));check(r.status===401&&l.events.length===0,'invalid username rejected');
l=loginFixture();r=await l.handler(request('{'));check(r.status===400,'malformed login request rejected');
check(r.headers.get('cache-control')==='no-store','credential responses never cached');
console.log(`PASS: ${assertions} staff account and username login assertions`);
