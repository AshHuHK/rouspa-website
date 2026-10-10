-- Product photographs only. Reuse catalog.manage; no new account permissions.
begin;

create or replace function spa_private.product_media_upload_allowed(p_bucket text,p_name text)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(p_bucket='product-media'
  and p_name ~ '^products/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  and spa_private.has_permission('catalog.manage'),false)
$$;
revoke all on function spa_private.product_media_upload_allowed(text,text) from public,anon,authenticated;
grant execute on function spa_private.product_media_upload_allowed(text,text) to authenticated,service_role;

-- PGlite business tests do not install the Supabase Storage service. Production
-- must have both tables; verify its configuration when deploying this migration.
do $$
begin
 if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
  raise notice 'Storage service not installed; product-media provisioning skipped';
  return;
 end if;

 insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('product-media','product-media',true,5242880,array['image/jpeg','image/png','image/webp'])
 on conflict(id) do nothing;

 -- Never publish or repurpose an existing private/unrelated bucket.
 if not exists(select 1 from storage.buckets where id='product-media'
  and name='product-media' and public and file_size_limit=5242880
  and allowed_mime_types @> array['image/jpeg','image/png','image/webp']::text[]
  and allowed_mime_types <@ array['image/jpeg','image/png','image/webp']::text[]) then
  raise exception 'PRODUCT_MEDIA_BUCKET_CONFLICT';
 end if;

 if not exists(select 1 from pg_policies where schemaname='storage'
  and tablename='objects' and policyname='spa_product_media_insert') then
  execute 'create policy spa_product_media_insert on storage.objects for insert to authenticated
   with check (spa_private.product_media_upload_allowed(bucket_id,name))';
 end if;
end $$;

notify pgrst,'reload schema';
commit;
