begin;

-- The public service menu has exactly four structural categories. Historical
-- categories remain archived because payroll tiers may reference them.
insert into public.spa_service_categories(code,name,name_en,active,display_order,archived_at) values
 ('duration_45','45 分鐘','45 minutes',true,45,null),
 ('duration_60','60 分鐘','60 minutes',true,60,null),
 ('duration_90','90 分鐘','90 minutes',true,90,null),
 ('duration_120','120 分鐘','120 minutes',true,120,null)
on conflict(code) do update set name=excluded.name,name_en=excluded.name_en,active=true,display_order=excluded.display_order,archived_at=null;

update public.spa_service_categories
set active=false,archived_at=coalesce(archived_at,now())
where code not in ('duration_45','duration_60','duration_90','duration_120') and active;

update public.spa_services s
set category_id=c.id
from public.spa_service_categories c
where c.code='duration_'||s.duration_minutes::text
  and s.duration_minutes in (45,60,90,120)
  and s.category_id is distinct from c.id;

create or replace function public.spa_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'settings',(select to_jsonb(s) from public.spa_settings s),'business',(select value from public.spa_business_settings where key='business'),'website',(select value from public.spa_business_settings where key='website'),
 'business_hours',coalesce((select jsonb_agg(to_jsonb(h) order by weekday) from public.spa_business_hours h),'[]'),
 'today_hours',(select to_jsonb(w) from spa_private.business_window((now() at time zone 'Asia/Taipei')::date) w),
 'service_categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order) from public.spa_service_categories c where c.active and c.archived_at is null and c.code in ('duration_45','duration_60','duration_90','duration_120')),'[]'),
 'services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('category_code',c.code,'category_name',c.name,'category_name_en',c.name_en) order by c.display_order,s.display_order,s.name)
   from public.spa_services s join public.spa_service_categories c on c.id=s.category_id
   where s.active and s.status='active' and s.online_booking_enabled and c.active and c.archived_at is null),'[]'),
 'website_services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('category_code',c.code,'category_name',c.name,'category_name_en',c.name_en) order by c.display_order,s.display_order,s.name)
   from public.spa_services s join public.spa_service_categories c on c.id=s.category_id
   where s.active and s.status='active' and s.website_visible and c.active and c.archived_at is null),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'name_en',s.name_en,'title',j.name,'title_en',j.name_en,'job_title_id',j.id,'specialty',s.specialty,'bio',s.bio,'photo_url',s.photo_url) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and s.is_bookable),'[]'),
 'website_staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'name_en',s.name_en,'title',j.name,'title_en',j.name_en,'job_title_id',j.id,'specialty',s.specialty,'bio',s.bio,'photo_url',s.photo_url) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and s.website_visible),'[]'),
 'skills',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_staff_services s where enabled),'[]'))
$$;

create or replace function public.spa_service_save_v2(p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare
 result uuid:=nullif(p_payload->>'id','')::uuid;
 old jsonb;
 category_code text;
 category_minutes int;
 requested_minutes int:=coalesce((p_payload->>'duration_minutes')::int,0);
 requested_category uuid:=nullif(p_payload->>'category_id','')::uuid;
begin
 perform spa_private.require_permission('catalog.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120 or requested_minutes not in (45,60,90,120) or coalesce((p_payload->>'price_cents')::bigint,-1)<0 or requested_category is null then raise exception 'SERVICE_CATEGORY_REQUIRED'; end if;
 select c.code,substring(c.code from '[0-9]+$')::int into category_code,category_minutes
 from public.spa_service_categories c where c.id=requested_category and c.active and c.archived_at is null
  and c.code in ('duration_45','duration_60','duration_90','duration_120');
 if category_code is null or category_minutes<>requested_minutes then raise exception 'SERVICE_DURATION_CATEGORY_MISMATCH'; end if;
 select to_jsonb(s) into old from public.spa_services s where s.id=result;
 if result is null then
  insert into public.spa_services(code,name,name_en,duration_minutes,buffer_minutes,price_cents,active,display_order,category_id,description,description_en,image_url,member_price_cents,online_booking_enabled,website_visible,status,website_content)
  values(coalesce(nullif(p_payload->>'code',''),'service_'||substr(replace(gen_random_uuid()::text,'-',''),1,10)),btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),requested_minutes,coalesce((p_payload->>'buffer_minutes')::int,15),(p_payload->>'price_cents')::bigint,
   coalesce((p_payload->>'status')='active',true),coalesce((p_payload->>'display_order')::int,0),requested_category,coalesce(p_payload->>'description',''),coalesce(p_payload->>'description_en',''),coalesce(p_payload->>'image_url',''),nullif(p_payload->>'member_price_cents','')::bigint,
   coalesce((p_payload->>'online_booking_enabled')::boolean,false),coalesce((p_payload->>'website_visible')::boolean,false),coalesce(p_payload->>'status','draft'),coalesce(p_payload->'website_content','{}'::jsonb)) returning id into result;
 else
  update public.spa_services set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),duration_minutes=requested_minutes,buffer_minutes=coalesce((p_payload->>'buffer_minutes')::int,buffer_minutes),price_cents=(p_payload->>'price_cents')::bigint,
   active=coalesce((p_payload->>'status')='active',active),display_order=coalesce((p_payload->>'display_order')::int,display_order),category_id=requested_category,description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),
   member_price_cents=nullif(p_payload->>'member_price_cents','')::bigint,online_booking_enabled=coalesce((p_payload->>'online_booking_enabled')::boolean,online_booking_enabled),website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible),status=coalesce(p_payload->>'status',status),website_content=coalesce(p_payload->'website_content',website_content)
  where id=result;
  if not found then raise exception 'NOT_FOUND'; end if;
 end if;
 perform spa_private.audit('service.saved',result::text,jsonb_build_object('old',old,'new',p_payload,'category_code',category_code)); return result;
end $$;

create or replace function public.spa_payroll_rule_delete(p_rule uuid,p_confirmation text) returns void
language plpgsql security definer set search_path='' as $$
declare target public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_confirmation<>'DELETE' then raise exception 'PAYROLL_RULE_DELETE_CONFIRMATION_REQUIRED'; end if;
 select * into target from public.spa_payroll_rule_versions where id=p_rule for update;
 if target.id is null then raise exception 'NOT_FOUND'; end if;
 if target.status='active' then raise exception 'PAYROLL_RULE_ACTIVE'; end if;
 if exists(select 1 from public.spa_payroll_runs where rule_version_id=p_rule) then raise exception 'PAYROLL_RULE_IN_USE'; end if;
 perform spa_private.audit('payroll.rule_deleted',p_rule::text,jsonb_build_object('version',target.version_no,'name',target.name,'status',target.status));
 delete from public.spa_payroll_rule_versions where id=p_rule;
end $$;

revoke all on function public.spa_payroll_rule_delete(uuid,text) from public,anon,authenticated;
grant execute on function public.spa_payroll_rule_delete(uuid,text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
