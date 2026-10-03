import { createClient } from 'npm:@supabase/supabase-js@2.117.2';

// Only this server function uses Auth Admin credentials. Never log request bodies/passwords.
export function createStaffHandler({ clientFactory, environment }) {
 const origins = ['https://www.rouspa.tw','https://rouspa.tw','http://localhost:5173','http://127.0.0.1:4178'];
 const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
 return async (req) => {
  const origin = req.headers.get('origin');
  const headers = { 'Content-Type':'application/json', 'Cache-Control':'no-store', 'Vary':'Origin',
   'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods':'POST, OPTIONS',
   ...(origins.includes(origin) ? {'Access-Control-Allow-Origin':origin} : {}) };
  const reply = (status, error, extra = {}) => new Response(JSON.stringify(error ? {error,...extra} : {ok:true,...extra}),{status,headers});
  if (origin && !origins.includes(origin)) return reply(403,'FORBIDDEN_ORIGIN');
  if (req.method === 'OPTIONS') return new Response(null,{status:204,headers});
  if (req.method !== 'POST') return reply(405,'METHOD_NOT_ALLOWED');
  const bearer = req.headers.get('authorization') || '';
  if (!bearer.startsWith('Bearer ')) return reply(401,'UNAUTHORIZED');
  try {
   const url = environment('SUPABASE_URL'), publicKey = environment('SUPABASE_ANON_KEY'), secret = environment('SUPABASE_SERVICE_ROLE_KEY');
   if (!url || !publicKey || !secret) return reply(503,'ACCOUNT_SERVICE_UNAVAILABLE');
   const caller = clientFactory(url,publicKey,{global:{headers:{Authorization:bearer}},auth:{persistSession:false,autoRefreshToken:false}});
   const identity = await caller.auth.getUser(bearer.slice(7));
   if (identity.error || !identity.data.user) return reply(401,'UNAUTHORIZED');
   const access = await caller.rpc('spa_session');
   if (access.error || access.data?.role !== 'owner') return reply(403,'FORBIDDEN');
   if (Number(req.headers.get('content-length')) > 8192) return reply(413,'INVALID_INPUT');
   const raw = await req.text();
   if (raw.length > 8192) return reply(413,'INVALID_INPUT');
   let input;
   try { input = JSON.parse(raw); } catch { return reply(400,'INVALID_INPUT'); }
   if (!input || typeof input !== 'object' || Array.isArray(input) || !uuid.test(input.staff_id || '')) return reply(400,'INVALID_INPUT');
   const {action,staff_id} = input;
   if (!['create','password','username','access','archive','restore'].includes(action)) return reply(400,'INVALID_INPUT');
   if (['create','access'].includes(action) && (typeof input.role !== 'string' || !/^[a-z][a-z0-9_]{1,31}$/.test(input.role) || input.role === 'owner')) return reply(400,'INVALID_INPUT');
   if (action === 'access' && typeof input.active !== 'boolean') return reply(400,'INVALID_INPUT');
   if (['create','password'].includes(action) && (typeof input.password !== 'string' || input.password.length < 12 || input.password.length > 128)) return reply(400,'PASSWORD_TOO_SHORT');
   const username = typeof input.username === 'string' ? input.username.trim().toLowerCase() : '';
   if (['create','username'].includes(action) && !/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)) return reply(400,'INVALID_USERNAME');
   const email = `${staff_id}@staff.rouspa.invalid`;
   if (['archive','restore'].includes(action) && (typeof input.reason !== 'string' || !input.reason.trim() || input.reason.length > 1000)) return reply(400,'REASON_REQUIRED');
   const target = await caller.rpc('spa_staff_account_target',{p_staff:staff_id});
   if (target.error) return reply(409,target.error.message.includes('OWNER_PROTECTED') ? 'OWNER_PROTECTED' : 'ACCOUNT_CONFLICT');
   const current = target.data.account;
   if (current?.role === 'owner' || current?.user_id === identity.data.user.id) return reply(403,'OWNER_PROTECTED');
   if (target.data.archived && !['restore','archive'].includes(action)) return reply(409,'STAFF_ARCHIVED');
   if (action === 'create' && current) return reply(409,'ACCOUNT_EXISTS');
   if (['password','username','access'].includes(action) && !current) return reply(404,'ACCOUNT_NOT_FOUND');
   const admin = clientFactory(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
   const link = (user,role,active,reset = false) => caller.rpc('spa_staff_account_link',{p_staff:staff_id,p_user:user,p_role:role,p_active:active,p_reset:reset,...(['create','username'].includes(action)?{p_username:username}:{})});
   if (action === 'create') {
    const created = await admin.auth.admin.createUser({email,password:input.password,email_confirm:true});
    if (created.error || !created.data.user) return reply(409,'ACCOUNT_CREATE_FAILED');
    const linked = await link(created.data.user.id,input.role,true);
    if (linked.error) {
     const cleanup = await admin.auth.admin.deleteUser(created.data.user.id);
     return reply(409,cleanup.error ? 'ACCOUNT_LINK_CLEANUP_REQUIRED' : linked.error.message.includes('USERNAME_TAKEN') ? 'USERNAME_TAKEN' : 'ACCOUNT_CONFLICT');
    }
    return reply(200,null,{username,active:true});
   }
   if (action === 'username') {
    const updated = await link(current.user_id,current.role,current.active,true);
    if (updated.error) return reply(409,updated.error.message.includes('USERNAME_TAKEN') ? 'USERNAME_TAKEN' : 'ACCOUNT_CONFLICT');
    return reply(200,null,{username});
   }
   if (action === 'password') {
    // Revoke earlier backend sessions before changing the Auth password, failing closed.
    const invalidated = await link(current.user_id,current.role,current.active,true);
    if (invalidated.error) return reply(409,'ACCOUNT_CONFLICT');
    const result = await admin.auth.admin.updateUserById(current.user_id,{password:input.password});
    if (result.error) return reply(409,'PASSWORD_RESET_FAILED');
    return reply(200,null,{username:current.username});
   }
   if (action === 'access') {
    // Disabling the database role immediately blocks even unexpired JWTs.
    const linked = await link(current.user_id,input.role,input.active);
    if (linked.error) return reply(409,'ACCOUNT_CONFLICT');
    const result = await admin.auth.admin.updateUserById(current.user_id,{ban_duration:input.active ? 'none' : '876000h'});
    if (result.error) return reply(409,'ACCOUNT_AUTH_SYNC_REQUIRED',{access_saved:true});
    return reply(200,null,{active:input.active});
   }
   const archived = await caller.rpc('spa_staff_archive',{p_staff:staff_id,p_archive:action==='archive',p_reason:input.reason.trim()});
   if (archived.error) return reply(409,archived.error.message.includes('EXISTING_BOOKINGS') ? 'EXISTING_BOOKINGS' : 'ACCOUNT_CONFLICT');
   if (current) {
    // Restoring a person leaves login disabled until the owner explicitly enables it.
    const result = await admin.auth.admin.updateUserById(current.user_id,{ban_duration:'876000h'});
    if (result.error) return reply(409,'ACCOUNT_AUTH_SYNC_REQUIRED',{access_saved:true});
   }
   return reply(200,null,{archived:action==='archive'});
  } catch {
   return reply(500,'ACCOUNT_SERVICE_ERROR');
  }
 };
}
if (typeof Deno !== 'undefined') Deno.serve(createStaffHandler({clientFactory:createClient,environment:key=>Deno.env.get(key)}));
