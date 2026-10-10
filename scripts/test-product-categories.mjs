import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { isProductCategoryAvailable, publicProductCatalog } from '../src/lib/product-categories.js';
import { productPresentationMark } from '../src/lib/catalog-presentation.js';

const db = new PGlite();
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const reject = async (operation, pattern) => { await assert.rejects(operation, pattern); checks++; };
await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory = new URL('../supabase/migrations/', import.meta.url);
const migration = '202610100001_product_categories.sql';
for (const file of (await readdir(directory)).filter(file => file < migration).sort()) {
  await db.exec(await readFile(new URL(file, directory), 'utf8'));
}

// Real legacy edge cases before migration: custom categories must survive, and
// an unclassified item must not disappear from either collection.
const customCategory = randomUUID(), legacyProduct = randomUUID();
await db.query("insert into spa_product_categories(id,code,name,display_order) values($1,'legacy_custom','既有自訂分類',95)", [customCategory]);
await db.query("insert into spa_products(id,sku,category_id,name,price_cents,status,website_visible,store_visible) values($1,'LEGACY-NO-CATEGORY',null,'原有未分類商品',12345,'active',true,true)", [legacyProduct]);
await db.query("insert into spa_inventory_entries(product_id,delta,reason) values($1,5,'分類遷移測試')", [legacyProduct]);
const originalCount = Number((await db.query('select count(*) count from spa_products')).rows[0].count);
await db.exec(await readFile(new URL(migration, directory), 'utf8'));
check(Number((await db.query('select count(*) count from spa_products')).rows[0].count) === originalCount, 'migration preserves every existing product');
check((await db.query('select id from spa_product_categories where id=$1', [customCategory])).rows.length === 1, 'migration preserves unknown existing category IDs');
check((await db.query('select c.code from spa_products p join spa_product_categories c on c.id=p.category_id where p.id=$1', [legacyProduct])).rows[0].code === 'uncategorized', 'legacy null-category items receive an explicit category');

const owner = randomUUID(), employee = randomUUID();
const staff = (await db.query("select id from spa_staff where active and employment_status='active' and archived_at is null order by display_order limit 1")).rows[0].id;
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)', [owner, 'category-owner@example.test', employee, 'category-staff@example.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name) values($1,'owner',null,true,null),($2,'therapist',$3,true,'category_staff')", [owner, employee, staff]);
async function call(user, name, args = []) {
  await db.exec('begin');
  try {
    await db.exec('set local role ' + (user ? 'authenticated' : 'anon'));
    await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)", [user || '', JSON.stringify({ iat: Math.floor(Date.now() / 1000) })]);
    const result = (await db.query(`select public.${name}(${args.map((_, index) => '$' + (index + 1)).join(',')}) result`, args)).rows[0].result;
    await db.exec('commit');
    return result;
  } catch (error) { await db.exec('rollback'); throw error; }
}
const admin = (name, args = []) => call(owner, name, args);
const storefront = () => call(null, 'spa_store_catalog');
await reject(() => call(null, 'spa_product_category_save', [{ name: '匿名禁止' }]), /permission denied/);
await reject(() => call(employee, 'spa_product_category_save', [{ name: '員工禁止' }]), /FORBIDDEN/);
await reject(() => call(employee, 'spa_product_category_delete', [customCategory, null, 'DELETE']), /FORBIDDEN/);

const category = await admin('spa_product_category_save', [{ name: '身體保養', name_en: 'Body care', code: 'body_care', display_mark: '潤', display_order: 1, active: true }]);
const emptyCategory = await admin('spa_product_category_save', [{ name: '空分類', name_en: '', display_order: 999, active: true }]);
await reject(() => admin('spa_product_category_save', [{ name: '重複代碼', code: 'body_care' }]), /PRODUCT_CATEGORY_CODE_TAKEN/);
await reject(() => admin('spa_product_category_save', [{ id: category, name: '改代碼', code: 'another_code' }]), /PRODUCT_CATEGORY_CODE_IMMUTABLE/);
await reject(() => admin('spa_product_category_save', [{ name: '不合法排序', display_order: 10001 }]), /INVALID_INPUT/);

const original = (await admin('spa_catalog_admin')).products.find(product => product.id === legacyProduct);
const productPayload = { ...original, category_id: category };
await admin('spa_product_save', [productPayload]);
let publicData = await storefront();
check(publicData.categories[0].id === category && publicData.categories[0].name === '身體保養', 'public category ordering follows editable server sort order');
check(!publicData.categories.some(row => row.id === emptyCategory || row.id === customCategory), 'empty categories never produce public category tabs');
check(publicData.products.some(row => row.id === legacyProduct && row.category_id === category && Number(row.inventory) === 5), 'product move preserves quantity and public membership');
check(publicData.products.every(row => !('cost_cents' in row) && !('barcode' in row) && !('low_stock_threshold' in row)), 'anonymous catalog excludes internal costs and operational fields');
assert.deepEqual(publicProductCatalog(publicData).categories.map(row => row.id), publicData.categories.map(row => row.id)); checks++;
check(productPresentationMark(original, publicData.categories[0]) === '潤', 'editable category mark is used by the shared product card renderer');

await admin('spa_product_category_save', [{ id: category, code: 'body_care', name: '日常潤養', name_en: 'Daily care', display_mark: '養', display_order: -10, active: true }]);
const catalog = await admin('spa_catalog_admin');
check(catalog.product_categories.find(row => row.id === category)?.code === 'body_care' && catalog.products.find(row => row.id === legacyProduct)?.category_name === '日常潤養', 'category rename retains IDs and updates admin/POS display names');
publicData = await storefront();
check(publicData.categories[0].name === '日常潤養' && publicData.categories[0].name_en === 'Daily care', 'public category labels change together with admin labels');

const sale = await admin('spa_pos_checkout', [randomUUID(), null, [{ item_type: 'product', item_id: legacyProduct, quantity: 1, staff_id: staff }], 0, 'cash', '分類成交快照測試']);
const snapshot = (await db.query('select name_snapshot,unit_price_cents,staff_id,quantity,net_total_cents from spa_order_items where order_id=$1', [sale.id])).rows;
const inventoryBefore = Number((await db.query('select sum(delta) quantity from spa_inventory_entries where product_id=$1', [legacyProduct])).rows[0].quantity);
const archived = await admin('spa_product_save', [{ sku: 'ARCHIVED-CATEGORY-TEST', name: '封存保養品', category_id: category, price_cents: 9999, status: 'archived', website_visible: false, store_visible: false }]);
await reject(() => admin('spa_product_category_delete', [category, null, 'DELETE']), /PRODUCT_CATEGORY_IN_USE/);
await reject(() => admin('spa_product_category_delete', [category, customCategory, 'WRONG']), /INVALID_CONFIRMATION/);
await reject(() => admin('spa_product_category_delete', [category, category, 'DELETE']), /INVALID_INPUT/);
const moved = await admin('spa_product_category_delete', [category, customCategory, 'DELETE']);
check(moved.products_moved === 2 && !(await db.query('select id from spa_product_categories where id=$1', [category])).rows.length, 'category deletion atomically moves active and archived items before deleting');
check((await db.query('select category_id from spa_products where id=$1', [archived])).rows[0].category_id === customCategory, 'archived goods are included in safe category migration');
assert.deepEqual((await db.query('select name_snapshot,unit_price_cents,staff_id,quantity,net_total_cents from spa_order_items where order_id=$1', [sale.id])).rows, snapshot); checks++;
check(Number((await db.query('select sum(delta) quantity from spa_inventory_entries where product_id=$1', [legacyProduct])).rows[0].quantity) === inventoryBefore, 'category movement cannot alter inventory or sales commission attribution');
await admin('spa_product_category_delete', [emptyCategory, null, 'DELETE']);
check(!(await db.query('select id from spa_product_categories where id=$1', [emptyCategory])).rows.length, 'empty category can be deleted without a replacement');

await admin('spa_product_category_save', [{ id: customCategory, code: 'legacy_custom', name: '既有自訂分類', active: false, display_order: 95 }]);
publicData = await storefront();
check(!publicData.products.some(row => row.id === legacyProduct) && !publicData.categories.some(row => row.id === customCategory), 'disabled category stops public products and tabs together');
check(!isProductCategoryAvailable({ category_id: customCategory }, (await admin('spa_catalog_admin')).product_categories), 'POS category availability uses the same active master record');
await reject(() => admin('spa_product_save', [{ sku: 'CANNOT-JOIN-OFF', name: '停用分類禁止新增', category_id: customCategory, price_cents: 1000 }]), /PRODUCT_CATEGORY_UNAVAILABLE/);
await admin('spa_product_save', [{ ...original, category_id: customCategory, name: '停用商品仍可編輯' }]);
check((await db.query('select name from spa_products where id=$1', [legacyProduct])).rows[0].name === '停用商品仍可編輯', 'existing goods in disabled categories can still be maintained');
await admin('spa_product_category_save', [{ id: customCategory, code: 'legacy_custom', name: '再度上架', active: true, display_order: 95 }]);
check((await storefront()).products.some(row => row.id === legacyProduct), 're-enabling a category restores already-published goods without copying records');

await db.query("update spa_business_settings set value=jsonb_set(value,'{zero_stock_behavior}','\"hide\"') where key='inventory'");
await db.query('insert into spa_inventory_entries(product_id,delta,reason) values($1,$2,$3)', [legacyProduct, -inventoryBefore, '清空庫存分類展示測試']);
publicData = await storefront();
check(!publicData.products.some(row => row.id === legacyProduct) && !publicData.categories.some(row => row.id === customCategory), 'hide-zero-stock removes the last visible item and its category together');
await db.query("update spa_business_settings set value=jsonb_set(value,'{zero_stock_behavior}','\"sold_out\"') where key='inventory'");
check((await storefront()).products.some(row => row.id === legacyProduct && Number(row.inventory) === 0), 'sold-out display policy retains the category and marks the product stock accurately');

// Defense against a stale public response while a realtime refresh is arriving.
const stale = publicProductCatalog({ categories: [{ id: 'active', name: 'Active', active: true }, { id: 'off', name: 'Off', active: false }], products: [{ id: 'p', category_id: 'off', inventory: 1 }, { id: 'q', category_id: 'active', inventory: 0 }], settings: { zero_stock_behavior: 'hide' } });
check(stale.products.length === 0 && stale.categories.length === 0, 'client fallback never displays stale disabled or empty categories');
await db.close();
console.log(`PASS: ${checks} editable product category and cross-catalog consistency assertions`);
