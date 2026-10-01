import { createClient } from 'npm:@supabase/supabase-js@2.117.2';
export function createLoginHandler({clientFactory,environment}) {
 return async req => {
  const origin=req.headers.get('origin');
  const allowed=['https://www.rouspa.tw','https://rouspa.tw','http://localhost:5173','http://127.0.0.1:4178'];
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin',
   'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS',
   ...(allowed.includes(origin)?{'Access-Control-Allow-Origin':origin}:{})};
  const reply=(status,data)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!allowed.includes(origin))return reply(403,{error:'FORBIDDEN_ORIGIN'});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply(405,{error:'METHOD_NOT_ALLOWED'});
  try {
   if(Number(req.headers.get('content-length'))>8192)return reply(413,{error:'INVALID_INPUT'});
   const raw=await req.text();if(raw.length>8192)return reply(413,{error:'INVALID_INPUT'});
   let body;try{body=JSON.parse(raw);}catch{return reply(400,{error:'INVALID_INPUT'});}
   const username=typeof body?.username==='string'?body.username.trim().toLowerCase():'';
   if(!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)||typeof body.password!=='string'||!body.password||body.password.length>128)return reply(401,{error:'INVALID_LOGIN'});
   const url=environment('SUPABASE_URL'),secret=environment('SUPABASE_SERVICE_ROLE_KEY'),key=environment('SUPABASE_ANON_KEY');
   if(!url||!secret||!key)return reply(503,{error:'ACCOUNT_SERVICE_UNAVAILABLE'});
   const server=clientFactory(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
   const target=await server.rpc('spa_staff_login_lookup',{p_username:username});
   if(target.error)return reply(503,{error:'ACCOUNT_SERVICE_UNAVAILABLE'});
   if(target.data?.limited)return reply(429,{error:'RATE_LIMIT'});
   const auth=clientFactory(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
   // Unknown names and wrong passwords receive the same error and go through Auth validation.
   const result=await auth.auth.signInWithPassword({email:target.data?.email||'unknown@staff.rouspa.invalid',password:body.password});
   if(!target.data||result.error||!result.data.session||result.data.user.id!==target.data.user_id)return reply(401,{error:'INVALID_LOGIN'});
   return reply(200,{access_token:result.data.session.access_token,refresh_token:result.data.session.refresh_token});
  }catch{return reply(500,{error:'ACCOUNT_SERVICE_ERROR'});}
 };
}
if(typeof Deno!=='undefined')Deno.serve(createLoginHandler({clientFactory:createClient,environment:key=>Deno.env.get(key)}));
