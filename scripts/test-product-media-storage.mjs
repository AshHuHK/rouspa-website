import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

// Storage metadata is enough to exercise PostgreSQL RLS here. Supabase's actual
// object bytes, MIME inspection and public HTTP delivery belong to Storage.
const db = new PGlite();
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const equal = (actual, expected, label) => { assert.deepEqual(actual, expected, label); checks++; };
const reject = async (operation, pattern, label) => { await assert.rejects(operation, pattern, label); checks++; };
await db.exec(`
 create role anon; create role authenticated; create role service_role;
 create schema auth;
 create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;
 grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
 create schema storage;
 create table storage.buckets(id text primary key,name text not null,public boolean not null default false,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text not null references storage.buckets(id),name text not null,unique(bucket_id,name));
 alter table storage.objects enable row level security;
 grant usage on schema storage to anon,authenticated;
 grant select,insert,update,delete on storage.objects to anon,authenticated;
 -- Give the fixture read access so UPDATE/DELETE tests cannot pass merely
 -- because rows were invisible. The release itself grants no listing policy.
 create policy fixture_read on storage.objects for select to authenticated using(true);
`);
const directory = new URL('../supabase/migrations/', import.meta.url);
const mediaMigration = '202610100006_product_media.sql';
const migrations = (await readdir(directory)).filter(file => file.endsWith('.sql')).sort();
for (const file of migrations.filter(file => file < mediaMigration)) {
  await db.exec(await readFile(new URL(file, directory), 'utf8'));
}
const originalPermissions = (await db.query('select role_code,permission_code from spa_role_permissions order by role_code,permission_code')).rows;
for (const file of migrations.filter(file => file >= mediaMigration)) {
  await db.exec(await readFile(new URL(file, directory), 'utf8'));
}
equal((await db.query('select role_code,permission_code from spa_role_permissions order by role_code,permission_code')).rows, originalPermissions, 'media migration cannot widen role permissions');

const bucket = (await db.query("select * from storage.buckets where id='product-media'")).rows[0];
check(bucket?.public === true && bucket.name === 'product-media', 'dedicated product-only bucket is publicly readable');
check(Number(bucket.file_size_limit) === 5 * 1024 * 1024, 'maximum upload size is exactly 5 MiB');
equal(bucket.allowed_mime_types.sort(), ['image/jpeg', 'image/png', 'image/webp'], 'only JPEG, PNG and WebP MIME types are configured');
const releasePolicies = (await db.query("select policyname,cmd,roles from pg_policies where schemaname='storage' and tablename='objects' and policyname<>'fixture_read'")).rows;
equal(releasePolicies, [{ policyname: 'spa_product_media_insert', cmd: 'INSERT', roles: ['authenticated'] }], 'release grants authenticated INSERT only, without listing, replacement or deletion');
check(!(await db.query("select has_function_privilege('anon','spa_private.product_media_upload_allowed(text,text)','execute') allowed")).rows[0].allowed, 'anonymous role cannot execute the permission predicate');
await db.exec("insert into storage.buckets(id,name,public) values('private-records','private-records',false)");

const owner = randomUUID(), employee = randomUUID(), curator = randomUUID(), unknownUser = randomUUID();
const people = (await db.query("select id from spa_staff where active and employment_status='active' and archived_at is null order by display_order limit 2")).rows;
check(people.length === 2, 'security fixtures use actual active seeded staff relationships');
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6),($7,$8)', [owner, 'photo-owner@example.test', employee, 'photo-staff@example.test', curator, 'photo-curator@example.test', unknownUser, 'photo-unassigned@example.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name) values($1,'owner',null,true,null),($2,'therapist',$3,true,'photo_staff'),($4,'manager',$5,true,'photo_curator')", [owner, employee, people[0].id, curator, people[1].id]);
// A permission added by the owner independently of this migration must be
// honored. Removing that existing permission must revoke upload immediately.
await db.exec("insert into spa_role_permissions(role_code,permission_code) values('manager','catalog.manage') on conflict do nothing");
const freshIat = Math.floor(Date.now() / 1000);
async function asUser(user, operation, iat = freshIat) {
  await db.exec('begin');
  try {
    await db.exec('set local role ' + (user ? 'authenticated' : 'anon'));
    await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)", [user || '', JSON.stringify({ iat })]);
    const result = await operation();
    await db.exec('commit');
    return result;
  } catch (error) { await db.exec('rollback'); throw error; }
}
const photoPath = (extension = 'png') => `products/${randomUUID()}.${extension}`;
const upload = (user, name = photoPath(), bucketId = 'product-media', iat = freshIat) => asUser(user, () => db.query('insert into storage.objects(bucket_id,name) values($1,$2)', [bucketId, name]), iat);
const deniedUpload = /row-level security policy/;

const ownerPhoto = photoPath('jpeg');
await upload(owner, ownerPhoto);
check((await db.query('select name from storage.objects where name=$1', [ownerPhoto])).rows.length === 1, 'owner can insert a new public product photograph');
for (const extension of ['jpg', 'png', 'webp']) await upload(owner, photoPath(extension));
checks++;
await upload(curator);
checks++;
await reject(() => upload(null), deniedUpload, 'anonymous uploads are refused even when the bucket is public');
await reject(() => upload(employee), deniedUpload, 'ordinary technician cannot upload product photographs');
await reject(() => upload(unknownUser), deniedUpload, 'authenticated customer without a backend role cannot upload');
await reject(() => upload(owner, photoPath(), 'private-records'), deniedUpload, 'catalog permission cannot write to an unrelated private bucket');
for (const name of [
  'products/photo.png', `other/${randomUUID()}.png`, `products/${randomUUID()}.gif`,
  `products/${randomUUID()}.svg`, `products/${randomUUID()}.PNG`,
  `products/../${randomUUID()}.png`, `products/${randomUUID()}.png/extra`,
  `products/${randomUUID()}.png?download=1`,
]) await reject(() => upload(owner, name), deniedUpload, 'noncanonical path is rejected: ' + name);
await reject(() => upload(owner, ownerPhoto), /duplicate key/, 'existing photograph cannot be silently overwritten');
await reject(() => asUser(owner, () => db.query('insert into storage.objects(bucket_id,name) values($1,$2) on conflict(bucket_id,name) do update set name=excluded.name returning id', ['product-media', ownerPhoto])), deniedUpload, 'explicit upsert cannot bypass missing Storage UPDATE policy');
check((await asUser(owner, () => db.query('select spa_private.product_media_upload_allowed(null,null) allowed'))).rows[0].allowed === false, 'null bucket and path inputs never authorize upload');

await db.exec("delete from spa_role_permissions where role_code='manager' and permission_code='catalog.manage'");
await reject(() => upload(curator), deniedUpload, 'revoking catalog.manage immediately blocks upload');
await db.exec("insert into spa_role_permissions(role_code,permission_code) values('manager','catalog.manage')");
await db.query('update spa_roles set active=false where user_id=$1', [curator]);
await reject(() => upload(curator), deniedUpload, 'disabled login remains denied despite its role permission');
await db.query('update spa_roles set active=true where user_id=$1', [curator]);
await db.exec("update spa_role_profiles set active=false where code='manager'");
await reject(() => upload(curator), deniedUpload, 'disabled role profile immediately blocks upload');
await db.exec("update spa_role_profiles set active=true where code='manager'");
await db.query('update spa_staff set active=false where id=$1', [people[1].id]);
await reject(() => upload(curator), deniedUpload, 'inactive employee cannot reuse a previously authorized login');
await db.query('update spa_staff set active=true where id=$1', [people[1].id]);
await db.query('update spa_roles set login_after=to_timestamp($2) where user_id=$1', [curator, freshIat + 60]);
await reject(() => upload(curator), deniedUpload, 'password reset login_after rejects the old JWT');
await upload(curator, photoPath(), 'product-media', freshIat + 61);
checks++;
await db.query('update spa_roles set active=false where user_id=$1', [owner]);
await reject(() => upload(owner), deniedUpload, 'owner still needs an active backend account');
await db.query('update spa_roles set active=true where user_id=$1', [owner]);

const oldName = ownerPhoto;
const updated = await asUser(owner, () => db.query('update storage.objects set name=$2 where name=$1 returning id', [oldName, photoPath()]));
check(updated.rows.length === 0, 'even owner receives no Storage replacement authority from this feature');
const deleted = await asUser(owner, () => db.query('delete from storage.objects where name=$1 returning id', [oldName]));
check(deleted.rows.length === 0, 'even owner receives no Storage object deletion authority from this feature');
check((await db.query('select id from storage.objects where name=$1', [oldName])).rows.length === 1, 'failed update/delete leave the original photograph intact');

const rpc = (user, name, args = []) => asUser(user, async () => (await db.query(`select public.${name}(${args.map((_, index) => '$' + (index + 1)).join(',')}) result`, args)).rows[0].result);
const imageUrl = `https://example.supabase.co/storage/v1/object/public/product-media/${ownerPhoto}`;
const productPayload = {
  sku: 'PHOTO-ROUNDTRIP', name: '商品資訊測試', name_en: 'Product information test',
  description: '溫和日常養護\n容量：250 mL\n使用方式：依產品標示使用',
  description_en: 'Daily care\nVolume: 250 mL\nUse according to the product label',
  image_url: imageUrl, price_cents: 34500, cost_cents: 12000,
  barcode: 'TEST-PHOTO-BARCODE', unit_label: '瓶', unit_label_en: 'bottle',
  low_stock_threshold: 2, status: 'active', website_visible: true, store_visible: true,
};
await reject(() => rpc(employee, 'spa_product_save', [productPayload]), /FORBIDDEN/, 'adding a photo cannot bypass product save permission');
const productId = await rpc(owner, 'spa_product_save', [productPayload]);
await db.query('insert into spa_inventory_entries(product_id,delta,reason) values($1,3,$2)', [productId, '商品照片本機測試']);
const saved = (await db.query('select * from spa_products where id=$1', [productId])).rows[0];
for (const key of ['image_url', 'description', 'description_en', 'name', 'name_en', 'unit_label', 'unit_label_en']) {
  equal(saved[key], productPayload[key], 'product save preserves ' + key);
}
check(Number(saved.price_cents) === 34500 && Number(saved.cost_cents) === 12000, 'photo metadata does not change price/cost currency units');
let publicProduct = (await rpc(null, 'spa_store_catalog')).products.find(row => row.id === productId);
check(Boolean(publicProduct), 'published product is still returned by the public catalog');
for (const key of ['image_url', 'description', 'description_en', 'name', 'name_en', 'unit_label', 'unit_label_en']) {
  equal(publicProduct[key], productPayload[key], 'anonymous storefront receives the published ' + key);
}
check(!('cost_cents' in publicProduct) && !('barcode' in publicProduct) && !('low_stock_threshold' in publicProduct), 'public photo/info response continues to exclude internal product fields');
await rpc(owner, 'spa_product_save', [{ ...productPayload, id: productId, image_url: '', description: '更新後的產品介紹' }]);
publicProduct = (await rpc(null, 'spa_store_catalog')).products.find(row => row.id === productId);
check(publicProduct.image_url === '' && publicProduct.description === '更新後的產品介紹', 'removing photo association and editing information is reflected in the public catalog');
check(Number(publicProduct.inventory) === 3, 'editing product information never changes inventory');
check((await db.query('select id from storage.objects where name=$1', [ownerPhoto])).rows.length === 1, 'removing a product photo association does not delete a shared Storage object');

const migrationSql = await readFile(new URL(mediaMigration, directory), 'utf8');
await db.exec(migrationSql);
check((await db.query("select count(*)::int count from pg_policies where schemaname='storage' and tablename='objects' and policyname='spa_product_media_insert'")).rows[0].count === 1, 'rerunning provisioning keeps one upload policy');
await db.exec("update storage.buckets set public=false where id='product-media'");
await reject(() => db.exec(migrationSql), /PRODUCT_MEDIA_BUCKET_CONFLICT/, 'existing private bucket refuses public provisioning');
await db.exec('rollback');
check((await db.query("select public from storage.buckets where id='product-media'")).rows[0].public === false, 'conflict transaction cannot expose an existing private bucket');
await db.exec("update storage.buckets set public=true,file_size_limit=1 where id='product-media'");
await reject(() => db.exec(migrationSql), /PRODUCT_MEDIA_BUCKET_CONFLICT/, 'incompatible upload limits refuse bucket repurposing');
await db.exec('rollback');
check(Number((await db.query("select file_size_limit from storage.buckets where id='product-media'")).rows[0].file_size_limit) === 1, 'conflict preserves preexisting bucket configuration');
await db.exec("update storage.buckets set file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp','image/svg+xml'] where id='product-media'");
await reject(() => db.exec(migrationSql), /PRODUCT_MEDIA_BUCKET_CONFLICT/, 'a preexisting bucket admitting additional MIME types is never repurposed');
await db.exec('rollback');
check((await db.query("select allowed_mime_types from storage.buckets where id='product-media'")).rows[0].allowed_mime_types.includes('image/svg+xml'), 'MIME conflict preserves preexisting bucket settings for review');

await db.exec('drop schema storage cascade');
await db.exec(migrationSql);
check((await db.query("select to_regprocedure('spa_private.product_media_upload_allowed(text,text)') is not null exists")).rows[0].exists, 'business-only PGlite environments still install the permission helper without Storage tables');
await db.close();
console.log(`PASS: ${checks} product photograph Storage security and public information roundtrip assertions`);
