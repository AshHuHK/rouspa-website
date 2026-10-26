import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';

async function load(name) {
  const source=(await readFile(new URL(`../supabase/functions/${name}/index.ts`,import.meta.url),'utf8')).replace(/^import .*\n/,'');
  return import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
}

const {createStaffHandler}=await load('staff-accounts');
const {createLoginHandler}=await load('staff-login');
const ownerId=randomUUID(),staffId=randomUUID(),userId=randomUUID();
const environment=key=>({SUPABASE_URL:'https://example.test',SUPABASE_ANON_KEY:'public-key',SUPABASE_SERVICE_ROLE_KEY:'server-secret'}[key]);
const state={account:null,password:null,banned:false,archived:false,staffActive:true};

const ownerClient={
  auth:{getUser:async()=>({data:{user:{id:ownerId}},error:null})},
  rpc:async(name,args)=>{
    if(name==='spa_session')return {data:{role:'owner'}};
    if(name==='spa_staff_account_target')return {data:{archived:state.archived,account:state.account&&{...state.account}}};
    if(name==='spa_staff_account_link'){
      state.account={
        user_id:args.p_user,
        role:args.p_role,
        active:args.p_active,
        username:args.p_username??state.account?.username,
        email:`${staffId}@staff.rouspa.invalid`
      };
      return {data:null};
    }
    if(name==='spa_staff_archive'){
      state.archived=args.p_archive;
      state.staffActive=false;
      if(state.account)state.account.active=false;
      return {data:null};
    }
    throw new Error(`Unexpected owner RPC: ${name}`);
  }
};

const adminClient={auth:{admin:{
  createUser:async({email,password})=>{
    assert.equal(email,`${staffId}@staff.rouspa.invalid`);
    state.password=password;
    return {data:{user:{id:userId}},error:null};
  },
  updateUserById:async(_id,changes)=>{
    if(Object.hasOwn(changes,'password'))state.password=changes.password;
    if(Object.hasOwn(changes,'ban_duration'))state.banned=changes.ban_duration!=='none';
    return {data:{user:{id:userId}},error:null};
  },
  deleteUser:async()=>{state.account=null;state.password=null;return {data:{},error:null};}
}}};

const loginLookupClient={rpc:async(name,{p_username})=>{
  assert.equal(name,'spa_staff_login_lookup');
  if(!state.account||state.account.username!==p_username||!state.account.active||state.archived||!state.staffActive)return {data:null,error:null};
  return {data:{email:state.account.email,user_id:userId},error:null};
}};
const passwordClient={auth:{signInWithPassword:async({email,password})=>{
  const valid=!state.banned&&state.account&&email===state.account.email&&password===state.password;
  return valid?{data:{user:{id:userId},session:{access_token:`access-${password}`,refresh_token:`refresh-${password}`}},error:null}:{data:{user:null,session:null},error:{message:'Invalid login'}};
}}};

const accountClientFactory=(_url,key)=>key==='server-secret'?adminClient:ownerClient;
const loginClientFactory=(_url,key)=>key==='server-secret'?loginLookupClient:passwordClient;
const accounts=createStaffHandler({clientFactory:accountClientFactory,environment});
const login=createLoginHandler({clientFactory:loginClientFactory,environment});
const origin='https://www.rouspa.tw';
const accountRequest=body=>new Request('https://example.test/functions/v1/staff-accounts',{method:'POST',headers:{origin,authorization:'Bearer owner-session','content-type':'application/json'},body:JSON.stringify({staff_id:staffId,...body})});
const loginRequest=(username,password)=>new Request('https://example.test/functions/v1/staff-login',{method:'POST',headers:{origin,'content-type':'application/json'},body:JSON.stringify({username,password})});
const action=async body=>{
  const response=await accounts(accountRequest(body));
  assert.equal(response.status,200,`${body.action} failed: ${await response.text()}`);
  return response;
};
const signIn=async(username,password,expected=200)=>{
  const response=await login(loginRequest(username,password));
  assert.equal(response.status,expected,`login ${username} returned ${response.status}`);
  if(expected===200)assert.ok((await response.json()).access_token,'successful login returns a session');
  else assert.equal((await response.json()).error,'INVALID_LOGIN','failed login never reveals account state');
};

await action({action:'create',username:'lifecycle.staff',password:'First-password-123!',role:'therapist'});
assert.deepEqual({username:state.account.username,role:state.account.role,active:state.account.active},{username:'lifecycle.staff',role:'therapist',active:true});
await signIn('lifecycle.staff','First-password-123!');

await action({action:'username',username:'lifecycle.renamed'});
await signIn('lifecycle.staff','First-password-123!',401);
await signIn('lifecycle.renamed','First-password-123!');

await action({action:'password',password:'Second-password-456!'});
await signIn('lifecycle.renamed','First-password-123!',401);
await signIn('lifecycle.renamed','Second-password-456!');

await action({action:'access',role:'receptionist',active:false});
assert.equal(state.account.role,'receptionist');
await signIn('lifecycle.renamed','Second-password-456!',401);

await action({action:'access',role:'receptionist',active:true});
await signIn('lifecycle.renamed','Second-password-456!');

await action({action:'archive',reason:'lifecycle test'});
assert.equal(state.banned,true,'archiving bans the Authentication identity');
await signIn('lifecycle.renamed','Second-password-456!',401);

await action({action:'restore',reason:'lifecycle test restore'});
assert.equal(state.banned,true,'restoring a person does not silently enable login');
assert.equal(state.account.active,false,'restored account remains disabled for owner review');
await signIn('lifecycle.renamed','Second-password-456!',401);

console.log('PASS: staff account lifecycle create, rename, password, disable, enable, archive and restore');
