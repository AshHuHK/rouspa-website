begin;

-- Add-ons are a single fourth public catalog category after the three fixed
-- treatment durations. The target table remains populated for compatibility,
-- but editors no longer need to assign add-ons to individual durations.
update public.spa_service_categories
set name='加購項目',name_en='Add-ons',active=true,display_order=900,archived_at=null
where code='add_on';

insert into public.spa_service_addon_targets(addon_service_id,parent_category_id)
select service.id,parent.id
from public.spa_services service
join public.spa_service_categories category on category.id=service.category_id and category.code='add_on'
cross join public.spa_service_categories parent
where parent.active and parent.archived_at is null
  and parent.code in ('duration_45','duration_90','duration_120')
on conflict do nothing;

create or replace function public.spa_service_save_v2(p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare
 result uuid:=nullif(p_payload->>'id','')::uuid;
 old jsonb;
 old_category_code text;
 requested_category uuid:=nullif(p_payload->>'category_id','')::uuid;
 requested_category_code text;
 requested_minutes int:=coalesce((p_payload->>'duration_minutes')::int,0);
 addon_category uuid;
begin
 perform spa_private.require_permission('catalog.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120 or requested_minutes not between 15 and 480 or coalesce((p_payload->>'price_cents')::bigint,-1)<0 then raise exception 'INVALID_INPUT'; end if;
 select id into addon_category from public.spa_service_categories where code='add_on' and active and archived_at is null;
 if addon_category is null then raise exception 'SERVICE_CATEGORY_REQUIRED'; end if;
 select to_jsonb(s),c.code into old,old_category_code from public.spa_services s left join public.spa_service_categories c on c.id=s.category_id where s.id=result;
 if result is not null and old is null then raise exception 'NOT_FOUND'; end if;

 if result is null or old_category_code='add_on' then
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
  insert into public.spa_service_addon_targets(addon_service_id,parent_category_id)
  select result,c.id from public.spa_service_categories c
  where c.active and c.archived_at is null and c.code in ('duration_45','duration_90','duration_120')
  on conflict do nothing;
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

revoke all on function public.spa_service_save_v2(jsonb) from public,anon,authenticated;
grant execute on function public.spa_service_save_v2(jsonb) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
