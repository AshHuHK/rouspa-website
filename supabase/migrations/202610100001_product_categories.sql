-- Editable product categories. IDs and codes remain stable when display copy
-- changes; product inventory and order snapshots are never reset by this flow.
begin;

alter table public.spa_product_categories add column if not exists display_mark text not null default '';
alter table public.spa_product_categories add column if not exists updated_at timestamptz not null default now();
update public.spa_product_categories set display_mark=case code
 when 'tea_cake' then '茶' when 'shampoo_bar' then '髮'
 when 'essential_oil' then '香' when 'tea_bag' then '飲' else display_mark end
where display_mark='';

-- A valid legacy category, including a custom one, is preserved unchanged.
-- Only genuinely unclassified products need an explicit category.
insert into public.spa_product_categories(code,name,name_en,display_order)
select 'uncategorized','未分類','Uncategorized',900
where exists(select 1 from public.spa_products where category_id is null)
on conflict(code) do nothing;
update public.spa_products set category_id=(select id from public.spa_product_categories where code='uncategorized')
where category_id is null;

create or replace function public.spa_product_category_save(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb; category_code text;
begin
 perform spa_private.require_permission('catalog.manage');
 perform pg_advisory_xact_lock(hashtext('spa-product-category-maintenance'));
 if jsonb_typeof(p_payload) is distinct from 'object'
  or length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 80
  or length(coalesce(p_payload->>'name_en',''))>120
  or length(btrim(coalesce(p_payload->>'display_mark','')))>2
  or coalesce((p_payload->>'display_order')::int,0) not between -10000 and 10000
 then raise exception 'INVALID_INPUT'; end if;
 if result is null then
  category_code:=coalesce(nullif(lower(btrim(p_payload->>'code')),''),'category_'||replace(gen_random_uuid()::text,'-',''));
  if category_code !~ '^[a-z][a-z0-9_-]{1,63}$' then raise exception 'INVALID_INPUT'; end if;
  if exists(select 1 from public.spa_product_categories where code=category_code) then raise exception 'PRODUCT_CATEGORY_CODE_TAKEN'; end if;
  insert into public.spa_product_categories(code,name,name_en,display_mark,active,display_order)
  values(category_code,btrim(p_payload->>'name'),btrim(coalesce(p_payload->>'name_en','')),
   btrim(coalesce(p_payload->>'display_mark','')),coalesce((p_payload->>'active')::boolean,true),
   coalesce((p_payload->>'display_order')::int,0)) returning id into result;
 else
  select to_jsonb(c) into old from public.spa_product_categories c where c.id=result for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if nullif(p_payload->>'code','') is not null and p_payload->>'code' is distinct from old->>'code'
  then raise exception 'PRODUCT_CATEGORY_CODE_IMMUTABLE'; end if;
  update public.spa_product_categories set name=btrim(p_payload->>'name'),name_en=btrim(coalesce(p_payload->>'name_en','')),
   display_mark=btrim(coalesce(p_payload->>'display_mark','')),active=coalesce((p_payload->>'active')::boolean,active),
   archived_at=case when coalesce((p_payload->>'active')::boolean,active) then null else archived_at end,
   display_order=coalesce((p_payload->>'display_order')::int,display_order),updated_at=now() where id=result;
 end if;
 perform spa_private.audit('product_category.saved',result::text,jsonb_build_object('old',old,'new',p_payload));
 return result;
end $$;

create or replace function public.spa_product_category_delete(p_category uuid,p_target uuid default null,p_confirmation text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare old jsonb; moved int:=0;
begin
 perform spa_private.require_permission('catalog.manage');
 perform pg_advisory_xact_lock(hashtext('spa-product-category-maintenance'));
 if p_confirmation is distinct from 'DELETE' then raise exception 'INVALID_CONFIRMATION'; end if;
 select to_jsonb(c) into old from public.spa_product_categories c where c.id=p_category for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_target is not null then
  if p_target=p_category then raise exception 'INVALID_INPUT'; end if;
  perform 1 from public.spa_product_categories where id=p_target and active and archived_at is null for update;
  if not found then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
  update public.spa_products set category_id=p_target,updated_at=now() where category_id=p_category;
  get diagnostics moved=row_count;
 elsif exists(select 1 from public.spa_products where category_id=p_category) then
  raise exception 'PRODUCT_CATEGORY_IN_USE';
 end if;
 delete from public.spa_product_categories where id=p_category;
 perform spa_private.audit('product_category.deleted',p_category::text,jsonb_build_object('old',old,'target_category_id',p_target,'products_moved',moved));
 return jsonb_build_object('result','deleted','products_moved',moved,'target_category_id',p_target);
end $$;

create or replace function public.spa_product_save(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb; category uuid:=nullif(p_payload->>'category_id','')::uuid; available boolean;
begin
 perform spa_private.require_permission('catalog.manage');
 perform pg_advisory_xact_lock(hashtext('spa-product-category-maintenance'));
 if jsonb_typeof(p_payload) is distinct from 'object'
  or length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120
  or length(btrim(coalesce(p_payload->>'sku',''))) not between 1 and 80
  or coalesce((p_payload->>'price_cents')::bigint,-1)<0 then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(p) into old from public.spa_products p where p.id=result for update;
 if result is not null and not found then raise exception 'NOT_FOUND'; end if;
 if category is null then
  category:=nullif(old->>'category_id','')::uuid;
  if category is null then
   insert into public.spa_product_categories(code,name,name_en,display_order)
   values('uncategorized','未分類','Uncategorized',900) on conflict(code) do nothing;
   select id into category from public.spa_product_categories where code='uncategorized';
  end if;
 end if;
 select active and archived_at is null into available from public.spa_product_categories where id=category;
 if not found then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
 -- Existing products can still be edited/archived while their category is off.
 -- New products or moves must choose an available category.
 if not available and (result is null or category is distinct from nullif(old->>'category_id','')::uuid)
 then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
 if result is null then
  insert into public.spa_products(sku,category_id,name,name_en,description,description_en,image_url,price_cents,compare_price_cents,cost_cents,barcode,unit_label,unit_label_en,low_stock_threshold,status,website_visible,store_visible,display_order)
  values(upper(btrim(p_payload->>'sku')),category,btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce(p_payload->>'description',''),coalesce(p_payload->>'description_en',''),coalesce(p_payload->>'image_url',''),(p_payload->>'price_cents')::bigint,nullif(p_payload->>'compare_price_cents','')::bigint,nullif(p_payload->>'cost_cents','')::bigint,coalesce(p_payload->>'barcode',''),coalesce(p_payload->>'unit_label',''),coalesce(p_payload->>'unit_label_en',''),coalesce((p_payload->>'low_stock_threshold')::int,2),coalesce(p_payload->>'status','draft'),coalesce((p_payload->>'website_visible')::boolean,false),coalesce((p_payload->>'store_visible')::boolean,false),coalesce((p_payload->>'display_order')::int,0)) returning id into result;
 else
  update public.spa_products set sku=upper(btrim(p_payload->>'sku')),category_id=category,name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),price_cents=(p_payload->>'price_cents')::bigint,
   compare_price_cents=nullif(p_payload->>'compare_price_cents','')::bigint,cost_cents=nullif(p_payload->>'cost_cents','')::bigint,barcode=coalesce(p_payload->>'barcode',''),unit_label=coalesce(p_payload->>'unit_label',''),unit_label_en=coalesce(p_payload->>'unit_label_en',''),low_stock_threshold=coalesce((p_payload->>'low_stock_threshold')::int,low_stock_threshold),status=coalesce(p_payload->>'status',status),website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible),store_visible=coalesce((p_payload->>'store_visible')::boolean,store_visible),display_order=coalesce((p_payload->>'display_order')::int,display_order),updated_at=now() where id=result;
 end if;
 perform spa_private.audit('product.saved',result::text,jsonb_build_object('old',old,'new',p_payload||jsonb_build_object('category_id',category)));
 return result;
end $$;

create or replace function public.spa_store_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 with visible_products as (
  select p.id,p.sku,p.category_id,p.name,p.name_en,p.description,p.description_en,p.image_url,p.price_cents,
   p.compare_price_cents,p.unit_label,p.unit_label_en,p.display_order,
   coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0) as inventory
  from public.spa_products p join public.spa_product_categories c on c.id=p.category_id
  where p.status='active' and p.website_visible and p.store_visible and c.active and c.archived_at is null
 ), published_products as (
  select p.* from visible_products p where coalesce((select value->>'zero_stock_behavior' from public.spa_business_settings where key='inventory'),'sold_out')<>'hide' or p.inventory>0
 ) select jsonb_build_object(
  'settings',(select value from public.spa_business_settings where key='inventory'),
  'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'name',c.name,'name_en',c.name_en,'display_mark',c.display_mark,'display_order',c.display_order,'active',true) order by c.display_order,c.name,c.id)
   from public.spa_product_categories c where c.active and c.archived_at is null and exists(select 1 from published_products p where p.category_id=c.id)),'[]'::jsonb),
  'products',coalesce((select jsonb_agg(to_jsonb(p) order by c.display_order,p.display_order,p.name,p.id)
   from published_products p join public.spa_product_categories c on c.id=p.category_id),'[]'::jsonb))
$$;

revoke all on function public.spa_product_category_save(jsonb),public.spa_product_category_delete(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.spa_product_category_save(jsonb),public.spa_product_category_delete(uuid,uuid,text) to authenticated,service_role;
revoke all on function public.spa_product_save(jsonb) from public,anon,authenticated;
grant execute on function public.spa_product_save(jsonb) to authenticated,service_role;
revoke all on function public.spa_store_catalog() from public,anon,authenticated;
grant execute on function public.spa_store_catalog() to anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
