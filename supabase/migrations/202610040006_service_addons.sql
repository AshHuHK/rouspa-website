begin;

-- The public treatment menu has three fixed main categories. Add-ons are
-- separate catalog items that can be shown under one or more main categories.
insert into public.spa_service_categories(code,name,name_en,active,display_order,archived_at) values
 ('duration_45','45 分鐘','45 minutes',true,45,null),
 ('duration_90','90 分鐘','90 minutes',true,90,null),
 ('duration_120','120 分鐘','120 minutes',true,120,null),
 ('add_on','加購項目','Add-ons',true,900,null)
on conflict(code) do update set name=excluded.name,name_en=excluded.name_en,active=true,display_order=excluded.display_order,archived_at=null;

update public.spa_service_categories
set active=false,archived_at=coalesce(archived_at,now())
where code='duration_60';

create table if not exists public.spa_service_addon_targets (
 addon_service_id uuid not null references public.spa_services(id) on delete cascade,
 parent_category_id uuid not null references public.spa_service_categories(id),
 primary key(addon_service_id,parent_category_id)
);

-- Existing 60-minute catalog entries become add-ons. Historical bookings keep
-- their own service, duration and price snapshots.
update public.spa_services s
set category_id=(select id from public.spa_service_categories where code='add_on'),
    online_booking_enabled=false
where s.category_id=(select id from public.spa_service_categories where code='duration_60');

insert into public.spa_service_addon_targets(addon_service_id,parent_category_id)
select s.id,c.id
from public.spa_services s
join public.spa_service_categories own_category on own_category.id=s.category_id and own_category.code='add_on'
cross join public.spa_service_categories c
where c.code in ('duration_45','duration_90','duration_120')
on conflict do nothing;

-- Preserve any title-based commission rule that previously targeted the
-- 60-minute category by moving it to the add-on category.
update public.spa_payroll_commission_tiers
set service_category_id=(select id from public.spa_service_categories where code='add_on')
where service_category_id=(select id from public.spa_service_categories where code='duration_60');

create or replace function public.spa_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'settings',(select to_jsonb(s) from public.spa_settings s),'business',(select value from public.spa_business_settings where key='business'),'website',(select value from public.spa_business_settings where key='website'),
 'business_hours',coalesce((select jsonb_agg(to_jsonb(h) order by weekday) from public.spa_business_hours h),'[]'),
 'today_hours',(select to_jsonb(w) from spa_private.business_window((now() at time zone 'Asia/Taipei')::date) w),
 'service_categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order) from public.spa_service_categories c where c.active and c.archived_at is null and c.code in ('duration_45','duration_90','duration_120')),'[]'),
 'services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('category_code',c.code,'category_name',c.name,'category_name_en',c.name_en) order by c.display_order,s.display_order,s.name)
   from public.spa_services s join public.spa_service_categories c on c.id=s.category_id
   where s.active and s.status='active' and s.online_booking_enabled and c.active and c.archived_at is null and c.code in ('duration_45','duration_90','duration_120')),'[]'),
 'website_services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('category_code',c.code,'category_name',c.name,'category_name_en',c.name_en) order by c.display_order,s.display_order,s.name)
   from public.spa_services s join public.spa_service_categories c on c.id=s.category_id
   where s.active and s.status='active' and s.website_visible and c.active and c.archived_at is null and c.code in ('duration_45','duration_90','duration_120')),'[]'),
 'website_addons',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object(
    'category_code','add_on','category_name',c.name,'category_name_en',c.name_en,
    'target_category_codes',coalesce((select jsonb_agg(parent.code order by parent.display_order) from public.spa_service_addon_targets target join public.spa_service_categories parent on parent.id=target.parent_category_id where target.addon_service_id=s.id),'[]'::jsonb)
   ) order by s.display_order,s.name)
   from public.spa_services s join public.spa_service_categories c on c.id=s.category_id
   where s.active and s.status='active' and s.website_visible and c.code='add_on'),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'name_en',s.name_en,'title',j.name,'title_en',j.name_en,'job_title_id',j.id,'specialty',s.specialty,'bio',s.bio,'photo_url',s.photo_url) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and s.is_bookable),'[]'),
 'website_staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'name_en',s.name_en,'title',j.name,'title_en',j.name_en,'job_title_id',j.id,'specialty',s.specialty,'bio',s.bio,'photo_url',s.photo_url) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and s.website_visible),'[]'),
 'skills',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_staff_services s where enabled),'[]'))
$$;

create or replace function public.spa_catalog_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('catalog.view');
 return jsonb_build_object(
  'service_categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_service_categories c),'[]'),
  'services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object(
    'category_name',c.name,'category_code',c.code,
    'target_category_ids',coalesce((select jsonb_agg(target.parent_category_id order by parent.display_order) from public.spa_service_addon_targets target join public.spa_service_categories parent on parent.id=target.parent_category_id where target.addon_service_id=s.id),'[]'::jsonb),
    'target_category_names',coalesce((select jsonb_agg(parent.name order by parent.display_order) from public.spa_service_addon_targets target join public.spa_service_categories parent on parent.id=target.parent_category_id where target.addon_service_id=s.id),'[]'::jsonb)
   ) order by case when c.code='add_on' then 1 else 0 end,c.display_order,s.display_order,s.name)
   from public.spa_services s left join public.spa_service_categories c on c.id=s.category_id),'[]'),
  'product_categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_product_categories c),'[]'),
  'products',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('category_name',c.name,'inventory',coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)) order by p.display_order)
   from public.spa_products p left join public.spa_product_categories c on c.id=p.category_id),'[]'),
  'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'job_title_name',j.name) order by s.display_order) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null),'[]'),
  'skills',coalesce((select jsonb_agg(to_jsonb(sk)) from public.spa_staff_services sk where sk.enabled),'[]'));
end $$;

create or replace function public.spa_service_save_v2(p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare
 result uuid:=nullif(p_payload->>'id','')::uuid;
 old jsonb;
 old_category_code text;
 requested_category uuid:=nullif(p_payload->>'category_id','')::uuid;
 requested_category_code text;
 requested_minutes int:=coalesce((p_payload->>'duration_minutes')::int,0);
 addon_category uuid;
 target_ids uuid[]:=array(select value::uuid from jsonb_array_elements_text(coalesce(p_payload->'target_category_ids','[]'::jsonb)));
begin
 perform spa_private.require_permission('catalog.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120 or requested_minutes not between 15 and 480 or coalesce((p_payload->>'price_cents')::bigint,-1)<0 then raise exception 'INVALID_INPUT'; end if;
 select id into addon_category from public.spa_service_categories where code='add_on' and active and archived_at is null;
 if addon_category is null then raise exception 'SERVICE_CATEGORY_REQUIRED'; end if;
 select to_jsonb(s),c.code into old,old_category_code from public.spa_services s left join public.spa_service_categories c on c.id=s.category_id where s.id=result;
 if result is not null and old is null then raise exception 'NOT_FOUND'; end if;

 if result is null or old_category_code='add_on' then
  if coalesce(array_length(target_ids,1),0)=0 or exists(
    select 1 from unnest(target_ids) target_id where not exists(
      select 1 from public.spa_service_categories c where c.id=target_id and c.active and c.archived_at is null and c.code in ('duration_45','duration_90','duration_120')
    )
  ) then raise exception 'SERVICE_ADDON_TARGET_REQUIRED'; end if;
  requested_category:=addon_category;
  if result is null then
   insert into public.spa_services(code,name,name_en,duration_minutes,buffer_minutes,price_cents,active,display_order,category_id,description,description_en,image_url,member_price_cents,online_booking_enabled,website_visible,status,website_content)
   values(coalesce(nullif(p_payload->>'code',''),'addon_'||substr(replace(gen_random_uuid()::text,'-',''),1,10)),btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),requested_minutes,coalesce((p_payload->>'buffer_minutes')::int,0),(p_payload->>'price_cents')::bigint,
    coalesce((p_payload->>'status')='active',true),coalesce((p_payload->>'display_order')::int,0),requested_category,coalesce(p_payload->>'description',''),coalesce(p_payload->>'description_en',''),coalesce(p_payload->>'image_url',''),nullif(p_payload->>'member_price_cents','')::bigint,
    false,coalesce((p_payload->>'website_visible')::boolean,false),coalesce(p_payload->>'status','draft'),coalesce(p_payload->'website_content','{}'::jsonb)) returning id into result;
  else
   update public.spa_services set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),duration_minutes=requested_minutes,buffer_minutes=coalesce((p_payload->>'buffer_minutes')::int,buffer_minutes),price_cents=(p_payload->>'price_cents')::bigint,
    active=coalesce((p_payload->>'status')='active',active),display_order=coalesce((p_payload->>'display_order')::int,display_order),category_id=addon_category,description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),
    member_price_cents=nullif(p_payload->>'member_price_cents','')::bigint,online_booking_enabled=false,website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible),status=coalesce(p_payload->>'status',status),website_content=coalesce(p_payload->'website_content',website_content)
   where id=result;
  end if;
  delete from public.spa_service_addon_targets where addon_service_id=result;
  insert into public.spa_service_addon_targets(addon_service_id,parent_category_id) select result,unnest(target_ids) on conflict do nothing;
 else
  select c.code into requested_category_code from public.spa_service_categories c where c.id=requested_category and c.active and c.archived_at is null and c.code in ('duration_45','duration_90','duration_120');
  if requested_category_code is null then raise exception 'SERVICE_CATEGORY_REQUIRED'; end if;
  if requested_category_code<>old_category_code then raise exception 'SERVICE_KIND_LOCKED'; end if;
  if substring(requested_category_code from '[0-9]+$')::int<>requested_minutes then raise exception 'SERVICE_DURATION_CATEGORY_MISMATCH'; end if;
  update public.spa_services set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),duration_minutes=requested_minutes,buffer_minutes=coalesce((p_payload->>'buffer_minutes')::int,buffer_minutes),price_cents=(p_payload->>'price_cents')::bigint,
   active=coalesce((p_payload->>'status')='active',active),display_order=coalesce((p_payload->>'display_order')::int,display_order),category_id=requested_category,description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),
   member_price_cents=nullif(p_payload->>'member_price_cents','')::bigint,online_booking_enabled=coalesce((p_payload->>'online_booking_enabled')::boolean,online_booking_enabled),website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible),status=coalesce(p_payload->>'status',status),website_content=coalesce(p_payload->'website_content',website_content)
  where id=result;
 end if;
 perform spa_private.audit('service.saved',result::text,jsonb_build_object('old',old,'new',p_payload,'kind',case when requested_category=addon_category then 'add_on' else 'main' end));
 return result;
end $$;

revoke all on table public.spa_service_addon_targets from public,anon,authenticated;
revoke all on function public.spa_service_save_v2(jsonb) from public,anon,authenticated;
grant execute on function public.spa_service_save_v2(jsonb) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
