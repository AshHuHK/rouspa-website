import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const db = new PGlite();
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const equal = (actual, expected, label) => { assert.deepEqual(actual, expected, label); checks++; };
const reject = async (operation, pattern, label) => { await assert.rejects(operation, pattern, label); checks++; };

await db.exec(`
 create role anon; create role authenticated; create role service_role;
 create schema auth;
 create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
 $$;
 create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb
 $$;
 grant usage on schema auth to anon,authenticated;
 grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
`);

const directory = new URL('../supabase/migrations/', import.meta.url);
const migration = '202610110002_product_sales_consistency.sql';
const files = (await readdir(directory)).filter(file => file.endsWith('.sql')).sort();
for (const file of files.filter(file => file < migration)) {
  await db.exec(await readFile(new URL(file, directory), 'utf8'));
}

const owner = randomUUID();
await db.query('insert into auth.users(id,email) values($1,$2)', [owner, 'product-consistency-owner@example.test']);
await db.query("insert into spa_roles(user_id,role,active) values($1,'owner',true)", [owner]);

async function call(user, name, args = []) {
  await db.exec('begin');
  try {
    await db.exec('set local role ' + (user ? 'authenticated' : 'anon'));
    await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)", [user || '', JSON.stringify({ iat: Math.floor(Date.now() / 1000) })]);
    const placeholders = args.map((_, index) => '$' + (index + 1)).join(',');
    const result = (await db.query(`select public.${name}(${placeholders}) result`, args)).rows[0].result;
    await db.exec('commit');
    return result;
  } catch (error) {
    await db.exec('rollback');
    throw error;
  }
}
const admin = (name, args = []) => call(owner, name, args);

const staffRows = (await db.query("select id from spa_staff where active and employment_status='active' and archived_at is null order by display_order,id limit 2")).rows;
assert.equal(staffRows.length, 2, 'fixture needs two active sales staff');
const staff = staffRows[0].id;
const secondStaff = staffRows[1].id;

// Production already has finalized wage periods when this migration runs. Build
// both affected sale shapes before applying it, then prove the metadata backfill
// neither fails on the payroll guard nor rewrites the saved payroll packet.
const historicalProduct = (await db.query(`
 select p.* from spa_products p join spa_product_categories c on c.id=p.category_id
 where p.status='active' and c.active and c.archived_at is null order by p.sku limit 1
`)).rows[0];
await db.query("insert into spa_inventory_entries(product_id,delta,reason,reference_type,created_by) values($1,2,'遷移回填測試庫存','adjustment',$2)", [historicalProduct.id, owner]);
const historicalOrder = await admin('spa_pos_checkout_with_coupon', [randomUUID(), null, [{ item_type: 'product', item_id: historicalProduct.id, quantity: 1, staff_id: staff }], 0, 'cash', '遷移回填測試']);
await db.query("update spa_orders set paid_at='2026-09-15T10:00:00+08:00' where id=$1", [historicalOrder.id]);
const historicalItem = (await db.query('select id from spa_order_items where order_id=$1', [historicalOrder.id])).rows[0].id;

const serviceFixture = (await db.query(`
 select s.id service_id,s.name,s.duration_minutes,s.price_cents,st.id staff_id
 from spa_services s join spa_staff_services ss on ss.service_id=s.id and ss.enabled
 join spa_staff st on st.id=ss.staff_id and st.active and st.employment_status='active' and st.archived_at is null
 join spa_job_titles jt on jt.id=st.job_title_id and jt.work_category='technician'
 where s.active and s.status='active' order by s.display_order,s.id limit 1
`)).rows[0];
const historicalCustomer = (await db.query("insert into spa_customers(name,phone) values('遷移回填顧客','0911000001') returning id")).rows[0].id;
const historicalAppointment = (await db.query(`
 insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,service_name_snapshot,duration_minutes_snapshot,price_cents,booking_preference)
 values($1,$2,$3,(select id from spa_rooms order by name limit 1),$4,'2026-09-16','2026-09-16T10:00:00+08:00','2026-09-16T11:00:00+08:00','2026-09-16T11:00:00+08:00','completed',$5,$5,$6,$7,'legacy') returning id
`, [randomUUID(), historicalCustomer, serviceFixture.staff_id, serviceFixture.service_id, serviceFixture.name, serviceFixture.duration_minutes, serviceFixture.price_cents])).rows[0].id;
const historicalCheckout = await admin('spa_checkout_with_coupon', [randomUUID(), historicalAppointment, 0, 0, null, 0, 'cash']);

// Reproduce every legacy refund shape before the request-fingerprint table
// exists. The upgrade must recognize their old cash/wallet ledgers without
// treating a valid retry as a request collision.
async function legacyCompletedAppointment(date) {
  const startsAt = `${date}T10:00:00+08:00`;
  return (await db.query(`
   insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,service_name_snapshot,duration_minutes_snapshot,price_cents,booking_preference)
   values($1,$2,$3,(select id from spa_rooms order by name limit 1),$4,$5,$6::timestamptz,$6::timestamptz+make_interval(mins=>$7),$6::timestamptz+make_interval(mins=>$7),'completed',$8,$8,$7,$9,'legacy') returning id
  `, [randomUUID(), historicalCustomer, serviceFixture.staff_id, serviceFixture.service_id, date, startsAt, serviceFixture.duration_minutes, serviceFixture.name, serviceFixture.price_cents])).rows[0].id;
}

await db.query("insert into spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values($1,$2,'topup',$3,'舊版退款升級測試儲值',$4)", [historicalCustomer, serviceFixture.price_cents * 2, randomUUID(), owner]);
const legacyRefunds = [];

const legacyCashAppointment = await legacyCompletedAppointment('2026-10-12');
const legacyCashCheckout = await admin('spa_checkout_with_coupon', [randomUUID(), legacyCashAppointment, 0, 0, null, 0, 'cash']);
const legacyCashRequest = randomUUID();
await admin('spa_refund', [legacyCashRequest, legacyCashAppointment, '舊版現金退款']);
legacyRefunds.push({ kind: 'cash', appointment: legacyCashAppointment, request: legacyCashRequest });

const legacyWalletAppointment = await legacyCompletedAppointment('2026-10-13');
await admin('spa_checkout_with_coupon', [randomUUID(), legacyWalletAppointment, 0, serviceFixture.price_cents, null, 0, 'cash']);
const legacyWalletRequest = randomUUID();
await admin('spa_refund', [legacyWalletRequest, legacyWalletAppointment, '舊版餘額退款']);
legacyRefunds.push({ kind: 'wallet', appointment: legacyWalletAppointment, request: legacyWalletRequest });

const legacyMixedAppointment = await legacyCompletedAppointment('2026-10-14');
const legacyMixedWallet = Math.max(1, Math.min(1234, serviceFixture.price_cents - 1));
await admin('spa_checkout_with_coupon', [randomUUID(), legacyMixedAppointment, 0, legacyMixedWallet, null, 0, 'cash']);
const legacyMixedRequest = randomUUID();
await admin('spa_refund', [legacyMixedRequest, legacyMixedAppointment, '舊版混合退款']);
legacyRefunds.push({ kind: 'mixed', appointment: legacyMixedAppointment, request: legacyMixedRequest });

const legacyPackageSaleRequest = randomUUID();
await admin('spa_package_sell', [legacyPackageSaleRequest, historicalCustomer, serviceFixture.service_id, '舊版退款升級測試套票', 2, serviceFixture.price_cents * 2, '2027-12-31T00:00:00+08:00', 'cash']);
const legacyPackage = (await db.query('select id from spa_packages where request_id=$1', [legacyPackageSaleRequest])).rows[0].id;
const legacyPackageAppointment = await legacyCompletedAppointment('2026-10-15');
await admin('spa_checkout_with_coupon', [randomUUID(), legacyPackageAppointment, 0, 0, legacyPackage, 0, 'cash']);
const legacyPackageRequest = randomUUID();
await admin('spa_refund', [legacyPackageRequest, legacyPackageAppointment, '舊版套票退款']);
legacyRefunds.push({ kind: 'package', appointment: legacyPackageAppointment, request: legacyPackageRequest });

const legacyNonRefundRequest = randomUUID();
await admin('spa_expense', [legacyNonRefundRequest, 100, 'cash', '舊版非退款請求衝突']);
assert.equal(Number((await db.query("select count(*) count from spa_cash_entries where request_id=$1 and category='refund'", [legacyCashRequest])).rows[0].count), 1, 'legacy cash refund fixture must create a real cash ledger');
assert.equal(Number((await db.query("select count(*) count from spa_wallet_entries where request_id=$1 and kind='refund'", [legacyWalletRequest])).rows[0].count), 1, 'legacy wallet refund fixture must create a real wallet ledger');
assert.deepEqual((await db.query(`
 select
  (select count(*)::int from spa_wallet_entries where request_id=$1 and kind='refund') wallet_count,
  (select count(*)::int from spa_cash_entries where request_id=$1 and category='refund') cash_count
`, [legacyMixedRequest])).rows[0], { wallet_count: 1, cash_count: 1 }, 'legacy mixed refund fixture must create both ledgers');
assert.equal(Number((await db.query('select count(*) count from spa_package_entries where appointment_id=$1', [legacyPackageAppointment])).rows[0].count), 2, 'legacy package refund fixture must consume and restore one session');

const activeRule = (await db.query("select id from spa_payroll_rule_versions where status='active' order by version_no desc limit 1")).rows[0].id;
const finalizedRun = (await db.query(`
 insert into spa_payroll_runs(period_start,period_end,rule_version_id,status,calculation_snapshot,created_by,finalized_by,finalized_at)
 values('2026-09-01','2026-09-30',$1,'finalized','{"migration_sentinel":"frozen"}',$2,$2,now()) returning id
`, [activeRule, owner])).rows[0].id;
await db.query(`
 insert into spa_payroll_items(run_id,staff_id,employment_type_snapshot,role_snapshot,calculation_snapshot)
 select $1,s.id,s.employment_type_code,s.title,'{"item_sentinel":"frozen"}' from spa_staff s where s.id=$2
`, [finalizedRun, staff]);
const draftRun = (await db.query(`
 insert into spa_payroll_runs(period_start,period_end,rule_version_id,status,calculation_snapshot,created_by)
 values('2026-08-01','2026-08-31',$1,'draft','{"migration_sentinel":"draft"}',$2) returning id
`, [activeRule, owner])).rows[0].id;
const frozenPacketBefore = (await db.query(`
 select jsonb_build_object('run',r.calculation_snapshot,'items',coalesce(jsonb_agg(i.calculation_snapshot order by i.id),'[]')) packet
 from spa_payroll_runs r left join spa_payroll_items i on i.run_id=r.id where r.id=$1 group by r.id
`, [finalizedRun])).rows[0].packet;

// These rows reproduce the production failure mode before the migration: an
// active product may intentionally be POS-only, or may have disagreeing legacy
// flags. Applying the migration must never publish either row by surprise.
const legacyRows = (await db.query("select id from spa_products where status='active' order by sku limit 2")).rows;
assert.equal(legacyRows.length, 2, 'fixture needs two active products');
await db.query('update spa_products set website_visible=false,store_visible=false where id=$1', [legacyRows[0].id]);
await db.query('update spa_products set website_visible=true,store_visible=false where id=$1', [legacyRows[1].id]);
await db.exec(await readFile(new URL(migration, directory), 'utf8'));
const migrated = (await db.query('select id,website_visible,store_visible from spa_products where id=any($1) order by id', [[legacyRows[0].id, legacyRows[1].id]])).rows;
check(migrated.every(row => row.website_visible === false && row.store_visible === false), 'migration preserves hidden products and resolves disagreeing legacy flags to hidden');
const frozenPacketAfter = (await db.query(`
 select jsonb_build_object('run',r.calculation_snapshot,'items',coalesce(jsonb_agg(i.calculation_snapshot order by i.id),'[]')) packet
 from spa_payroll_runs r left join spa_payroll_items i on i.run_id=r.id where r.id=$1 group by r.id
`, [finalizedRun])).rows[0].packet;
equal(frozenPacketAfter, frozenPacketBefore, 'migration preserves finalized run and item packet JSON exactly');
check(!(await db.query('select needs_recalculation from spa_payroll_runs where id=$1', [finalizedRun])).rows[0].needs_recalculation, 'migration never dirties a finalized payroll run');
check((await db.query('select needs_recalculation from spa_payroll_runs where id=$1', [draftRun])).rows[0].needs_recalculation, 'migration marks existing draft packets for deterministic recalculation');
const historicalMetadata = (await db.query(`
 select i.line_position,i.commission_rule_version_id,ch.commission_bps_snapshot,ch.commission_rule_version_id checkout_rule
 from spa_order_items i cross join spa_checkouts ch where i.id=$1 and ch.id=$2
`, [historicalItem, historicalCheckout.id])).rows[0];
check(Number(historicalMetadata.line_position) === 1 && historicalMetadata.commission_rule_version_id !== null, 'migration backfills finalized POS line order and rule metadata');
check(historicalMetadata.commission_bps_snapshot !== null && historicalMetadata.checkout_rule !== null, 'migration backfills finalized checkout rate and rule metadata');
await reject(() => db.query('update spa_order_items set line_position=line_position+1 where id=$1', [historicalItem]), /PAYROLL_LOCKED/, 'restored item guard protects finalized metadata after migration');
await reject(() => db.query('update spa_checkouts set commission_bps_snapshot=commission_bps_snapshot+1 where id=$1', [historicalCheckout.id]), /PAYROLL_LOCKED/, 'restored checkout guard protects finalized metadata after migration');
const privileges = (await db.query(`
 select
  has_function_privilege('authenticated','public.spa_checkout(uuid,uuid,bigint,bigint,uuid,bigint,text)','EXECUTE') checkout_base,
  has_function_privilege('authenticated','public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text)','EXECUTE') pos_base,
  has_function_privilege('authenticated','public.spa_checkout_with_coupon(uuid,uuid,bigint,bigint,uuid,bigint,text,uuid)','EXECUTE') checkout_wrapper,
  has_function_privilege('authenticated','public.spa_pos_checkout_with_coupon(uuid,uuid,jsonb,bigint,text,text,uuid,bigint)','EXECUTE') pos_wrapper
`)).rows[0];
check(!privileges.checkout_base && !privileges.pos_base, 'authenticated clients cannot bypass request fingerprints through raw checkout functions');
check(privileges.checkout_wrapper && privileges.pos_wrapper, 'authenticated clients retain both fingerprinted checkout wrappers');

for (const legacyRefund of legacyRefunds) {
  await reject(
    () => admin('spa_refund', [legacyRefund.request, legacyRefund.appointment, `重試${legacyRefund.kind}`]),
    /ALREADY_REFUNDED/,
    `a real pre-migration ${legacyRefund.kind} refund retry reports already refunded`,
  );
}
await reject(
  () => admin('spa_refund', [legacyCashRequest, legacyWalletAppointment, '跨預約重試']),
  /REQUEST_CONFLICT/,
  'a legacy refund request cannot be reused for another appointment',
);
await reject(
  () => admin('spa_refund', [legacyNonRefundRequest, legacyCashAppointment, '非退款請求重用']),
  /REQUEST_CONFLICT/,
  'a legacy non-refund request id cannot be reused for a refund',
);

const classifiedProfile = (await db.query(`
 select p.job_title_id,p.employment_type_code,j.name title
 from spa_payroll_version_profiles p join spa_payroll_rule_versions v on v.id=p.rule_version_id and v.status='active'
 join spa_job_titles j on j.id=p.job_title_id and j.work_category='technician' and not j.legacy
 where p.active and p.employment_type_code<>'contractor'
 order by case p.employment_type_code when 'full_time' then 0 else 1 end,j.display_order limit 1
`)).rows[0];
const refundStaff = (await db.query(`
 insert into spa_staff(name,title,job_title_id,employment_type_code,hire_date,active,employment_status,is_bookable)
 values('退款一致性技師',$1,$2,$3,'2026-01-01',true,'active',true) returning id
`, [classifiedProfile.title, classifiedProfile.job_title_id, classifiedProfile.employment_type_code])).rows[0].id;
await db.query('insert into spa_staff_services(staff_id,service_id,enabled) values($1,$2,true)', [refundStaff, serviceFixture.service_id]);
async function completedAppointment(date, hour) {
  const startsAt = `${date}T${String(hour).padStart(2, '0')}:00:00+08:00`;
  return (await db.query(`
   insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,service_name_snapshot,duration_minutes_snapshot,price_cents,booking_preference)
   values($1,$2,$3,(select id from spa_rooms order by name limit 1),$4,$5,$6::timestamptz,$6::timestamptz+make_interval(mins=>$7),$6::timestamptz+make_interval(mins=>$7),'completed',$8,$8,$7,$9,'legacy') returning id
  `, [randomUUID(), historicalCustomer, refundStaff, serviceFixture.service_id, date, startsAt, serviceFixture.duration_minutes, serviceFixture.name, serviceFixture.price_cents])).rows[0].id;
}

await db.query("insert into spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values($1,10000,'topup',$2,'退款測試儲值',$3)", [historicalCustomer, randomUUID(), owner]);
const refundableAppointment = await completedAppointment('2026-10-20', 10);
const sourceCoupon = (await db.query("insert into spa_coupons(customer_id,appointment_id,code,title,amount_cents,expires_at) values($1,$2,$3,'來源預約券',5000,now()+interval '30 days') returning id", [historicalCustomer, refundableAppointment, `SOURCE-${randomUUID()}`])).rows[0].id;
const coupons = await admin('spa_customer_coupons_admin', [historicalCustomer]);
equal(coupons.find(coupon => coupon.id === sourceCoupon).appointment_id, refundableAppointment, 'coupon admin projection exposes the issuing appointment for UI filtering');
await reject(
  () => admin('spa_checkout_with_coupon', [randomUUID(), refundableAppointment, 0, 0, null, 0, 'cash', sourceCoupon]),
  /COUPON_SOURCE_APPOINTMENT/,
  'an appointment cannot redeem the review reward it issued',
);
check((await db.query('select status from spa_coupons where id=$1', [sourceCoupon])).rows[0].status === 'active', 'source-appointment coupon rejection leaves the coupon active');
const walletUse = Math.min(2000, Number(serviceFixture.price_cents));
const refundableCheckout = await admin('spa_checkout_with_coupon', [randomUUID(), refundableAppointment, 0, walletUse, null, 0, 'cash', null]);
check(refundableCheckout.id !== null, 'authenticated appointment wrapper still completes checkout after raw RPC revocation');

await reject(() => admin('spa_refund', [null, refundableAppointment, '退款']), /INVALID_INPUT/, 'refund rejects a null request id');
check((await db.query('select refunded_at is null pending from spa_checkouts where id=$1', [refundableCheckout.id])).rows[0].pending, 'invalid refund leaves checkout untouched');
const refundRequest = randomUUID();
await admin('spa_refund', [refundRequest, refundableAppointment, '  顧客取消退款  ']);
await admin('spa_refund', [refundRequest, refundableAppointment, '顧客取消退款']);
const refundState = (await db.query(`
 select r.reason,ch.refund_reason,
  (select count(*)::int from spa_refund_requests where request_id=$1) request_count,
  (select count(*)::int from spa_wallet_entries where request_id=$1) wallet_count,
  (select count(*)::int from spa_cash_entries where request_id=$1) cash_count
 from spa_refund_requests r join spa_checkouts ch on ch.id=r.checkout_id where r.request_id=$1
`, [refundRequest])).rows[0];
equal(refundState.reason, '顧客取消退款', 'refund stores the normalized reason');
equal(refundState.refund_reason, '顧客取消退款', 'checkout stores the same normalized refund reason');
equal([refundState.request_count, refundState.wallet_count, refundState.cash_count], [1, walletUse > 0 ? 1 : 0, Number(refundableCheckout.cash_cents) > 0 ? 1 : 0], 'same-payload retry cannot duplicate refund ledgers');
await reject(() => admin('spa_refund', [refundRequest, refundableAppointment, '改過的原因']), /REQUEST_CONFLICT/, 'same refund request with another reason conflicts');
await reject(() => admin('spa_refund', [refundRequest, historicalAppointment, '顧客取消退款']), /REQUEST_CONFLICT/, 'same refund request with another appointment conflicts');
await reject(() => admin('spa_refund', [randomUUID(), refundableAppointment, '再次退款']), /ALREADY_REFUNDED/, 'a new request cannot refund an already refunded checkout');
const refundBackup = await admin('spa_backup_export', ['appointments', '2026-10-20', '2026-10-20']);
check(refundBackup.refund_requests.some(request => request.request_id === refundRequest && request.appointment_id === refundableAppointment), 'appointment backup preserves refund idempotency and audit records before reset');
await admin('spa_reset_business_data', ['appointments', '2026-10-20', '2026-10-20', 'RESET']);
check(Number((await db.query('select count(*) count from spa_refund_requests where request_id=$1', [refundRequest])).rows[0].count) === 0, 'appointment reset removes the live refund request only after it was exported');

const legacyRefundAppointment = await completedAppointment('2026-10-21', 10);
const legacyRefundCheckout = await admin('spa_checkout_with_coupon', [randomUUID(), legacyRefundAppointment, 0, 0, null, 0, 'cash', null]);
await db.query("update spa_checkouts set refunded_at=now(),refund_reason='舊版已退款' where id=$1", [legacyRefundCheckout.id]);
await reject(() => admin('spa_refund', [randomUUID(), legacyRefundAppointment, '舊版重試']), /ALREADY_REFUNDED/, 'legacy refunded checkout without a request record reports already refunded');

const lockedRefundAppointment = await completedAppointment('2026-11-10', 10);
const lockedRefundCheckout = await admin('spa_checkout_with_coupon', [randomUUID(), lockedRefundAppointment, 0, walletUse, null, 0, 'cash', null]);
await db.query(`
 insert into spa_payroll_runs(period_start,period_end,rule_version_id,status,calculation_snapshot,created_by,finalized_by,finalized_at)
 values('2026-11-01','2026-11-30',$1,'finalized','{"refund_lock":"frozen"}',$2,$2,now())
`, [activeRule, owner]);
const lockedRefundRequest = randomUUID();
const walletBeforeLockedRefund = Number((await db.query('select coalesce(sum(amount_cents),0) balance from spa_wallet_entries where customer_id=$1', [historicalCustomer])).rows[0].balance);
await reject(() => admin('spa_refund', [lockedRefundRequest, lockedRefundAppointment, '已結薪不可退款']), /PAYROLL_LOCKED/, 'finalized payroll blocks a refund fact change');
const failedRefundState = (await db.query(`
 select
  (select count(*)::int from spa_refund_requests where request_id=$1) request_count,
  (select count(*)::int from spa_wallet_entries where request_id=$1) wallet_count,
  (select count(*)::int from spa_cash_entries where request_id=$1) cash_count,
  (select refunded_at is null from spa_checkouts where id=$2) checkout_unchanged,
  (select coalesce(sum(amount_cents),0) from spa_wallet_entries where customer_id=$3) wallet_balance
`, [lockedRefundRequest, lockedRefundCheckout.id, historicalCustomer])).rows[0];
equal([failedRefundState.request_count, failedRefundState.wallet_count, failedRefundState.cash_count], [0, 0, 0], 'failed refund rolls back request, wallet and cash rows');
check(failedRefundState.checkout_unchanged && Number(failedRefundState.wallet_balance) === walletBeforeLockedRefund, 'failed refund preserves checkout and wallet balance atomically');

const category = (await db.query("select id from spa_product_categories where active and archived_at is null order by display_order limit 1")).rows[0].id;
const storefront = () => call(null, 'spa_store_catalog');
const row = id => db.query('select * from spa_products where id=$1', [id]).then(result => result.rows[0]);
const adjustInventory = (productId, delta, reason, request = randomUUID()) => admin('spa_inventory_adjust', [request, productId, delta, reason]);

const baseProduct = {
  sku: 'CONSISTENCY-POS-ONLY',
  category_id: category,
  name: 'POS 專用測試商品',
  name_en: 'POS-only test product',
  description: '測試官網與 POS 通路差異',
  description_en: 'Tests storefront and POS channel separation',
  image_url: '',
  price_cents: 12345,
  compare_price_cents: null,
  cost_cents: 5000,
  barcode: 'CONSISTENCY-POS-ONLY',
  unit_label: '件',
  unit_label_en: 'item',
  low_stock_threshold: 1,
  display_order: 999,
  status: 'active',
  public_visible: false,
};
const product = await admin('spa_product_save', [baseProduct]);
const openingStockRequest = randomUUID();
await adjustInventory(product, 3, '一致性測試初始庫存', openingStockRequest);
await adjustInventory(product, 3, '一致性測試初始庫存', openingStockRequest);
equal(Number((await db.query('select count(*) count from spa_inventory_entries where request_id=$1', [openingStockRequest])).rows[0].count), 1, 'retrying the same inventory request writes exactly one ledger entry');
equal(Number((await db.query('select coalesce(sum(delta),0) quantity from spa_inventory_entries where product_id=$1', [product])).rows[0].quantity), 3, 'retrying the same inventory request cannot double the stock adjustment');
await reject(
  () => adjustInventory(product, 4, '一致性測試初始庫存', openingStockRequest),
  /REQUEST_CONFLICT/,
  'reusing an inventory request id with a changed payload is rejected',
);
let saved = await row(product);
check(saved.status === 'active' && !saved.website_visible && !saved.store_visible, 'active POS-only save synchronizes both legacy visibility flags to false');
check(!(await storefront()).products.some(item => item.id === product), 'active POS-only product stays out of the public storefront');

const order = await admin('spa_pos_checkout_with_coupon', [randomUUID(), null, [{ item_type: 'product', item_id: product, quantity: 1, staff_id: staff }], 0, 'cash', 'POS-only consistency sale', null, baseProduct.price_cents]);
check(order.status === 'paid' && Number(order.total_cents) === baseProduct.price_cents, 'website-hidden active product remains sellable through POS');
check(Number((await db.query('select coalesce(sum(delta),0) quantity from spa_inventory_entries where product_id=$1', [product])).rows[0].quantity) === 2, 'POS sale deducts exactly one unit from the shared inventory ledger');

await admin('spa_product_save', [{ ...baseProduct, id: product, public_visible: true }]);
saved = await row(product);
check(saved.website_visible && saved.store_visible, 'single public switch synchronizes both legacy visibility flags to true');
check((await storefront()).products.some(item => item.id === product), 'published active product appears in the public storefront');

await admin('spa_product_save', [{ ...baseProduct, id: product, status: 'draft', public_visible: true }]);
saved = await row(product);
check(saved.status === 'draft' && !saved.website_visible && !saved.store_visible, 'non-active lifecycle state forcibly clears both public flags');
check(!(await storefront()).products.some(item => item.id === product), 'draft product cannot leak into the public storefront');

await admin('spa_product_save', [{ ...baseProduct, id: product, status: 'active', public_visible: true }]);
await admin('spa_catalog_bulk', ['product', [product], 'unpublish', null]);
saved = await row(product);
check(saved.status === 'active' && !saved.website_visible && !saved.store_visible, 'bulk website unpublish keeps an active product available to POS while hiding it publicly');
const secondOrder = await admin('spa_pos_checkout_with_coupon', [randomUUID(), null, [{ item_type: 'product', item_id: product, quantity: 1, staff_id: staff }], 0, 'cash', 'POS sale after website unpublish', null, baseProduct.price_cents]);
check(secondOrder.status === 'paid', 'bulk website unpublish does not disable POS sale');

// A one-cent order discount cannot be split evenly between equal lines. Keep
// the cart position as a persisted sale fact so repeated equivalent orders
// always award the same cent (and therefore the same commission) to the same
// product/staff line rather than relying on random UUID order.
const roundingA = await admin('spa_product_save', [{ ...baseProduct, sku: 'CONSISTENCY-ROUNDING-A', barcode: '', name: '等價商品 A', price_cents: 101, display_order: 1001 }]);
const roundingB = await admin('spa_product_save', [{ ...baseProduct, sku: 'CONSISTENCY-ROUNDING-B', barcode: '', name: '等價商品 B', price_cents: 101, display_order: 1002 }]);
await adjustInventory(roundingA, 4, '折扣分攤測試庫存');
await adjustInventory(roundingB, 4, '折扣分攤測試庫存');
const roundingCart = [
  { item_type: 'product', item_id: roundingA, quantity: 1, staff_id: staff },
  { item_type: 'product', item_id: roundingB, quantity: 1, staff_id: secondStaff },
];
let allocationSignature;
for (let iteration = 0; iteration < 3; iteration++) {
  const sale = await admin('spa_pos_checkout_with_coupon', [randomUUID(), null, roundingCart, 1, 'cash', '一分折扣確定性測試', null, 201]);
  const lines = (await db.query(`
   select product_id,staff_id,line_position,line_total_cents,net_total_cents,
    commission_bps_snapshot,commission_cents
   from spa_order_items where order_id=$1 order by line_position
  `, [sale.id])).rows.map(line => ({
    product_id: line.product_id,
    staff_id: line.staff_id,
    line_position: Number(line.line_position),
    gross: Number(line.line_total_cents),
    net: Number(line.net_total_cents),
    commission_bps: Number(line.commission_bps_snapshot),
    commission: Number(line.commission_cents),
  }));
  equal(lines.map(line => line.line_position), [1, 2], `order ${iteration + 1} persists the original JSON cart order`);
  equal(lines.map(line => line.net), [100, 101], `order ${iteration + 1} assigns the indivisible discount cent deterministically`);
  equal(lines.reduce((sum, line) => sum + line.net, 0), Number(sale.total_cents), `order ${iteration + 1} line net totals equal the paid order total`);
  check(lines.every(line => line.commission === Math.round(line.net * line.commission_bps / 10000)), `order ${iteration + 1} commissions derive from the deterministic net amounts`);
  if (allocationSignature === undefined) allocationSignature = lines;
  else equal(lines, allocationSignature, `order ${iteration + 1} repeats the exact product/staff net and commission allocation`);
}

const disabledCategory = await admin('spa_product_category_save', [{ name: '停用分類測試', code: 'consistency_disabled', active: true, display_order: 999 }]);
const disabledProduct = await admin('spa_product_save', [{ ...baseProduct, sku: 'CONSISTENCY-DISABLED-CATEGORY', barcode: '', category_id: disabledCategory, name: '停用分類商品', status: 'draft', public_visible: false }]);
await admin('spa_product_category_save', [{ id: disabledCategory, code: 'consistency_disabled', name: '停用分類測試', active: false, display_order: 999 }]);
await reject(
  () => admin('spa_catalog_bulk', ['product', [disabledProduct], 'publish', null]),
  /PRODUCT_CATEGORY_UNAVAILABLE/,
  'bulk publish rejects a product whose category is disabled',
);
saved = await row(disabledProduct);
check(saved.status === 'draft' && !saved.website_visible && !saved.store_visible, 'failed category publication rolls back every product channel change');

const quantityBeforeFailure = Number((await db.query('select coalesce(sum(delta),0) quantity from spa_inventory_entries where product_id=$1', [product])).rows[0].quantity);
equal(quantityBeforeFailure, 1, 'test fixture reaches one remaining unit after two POS sales');
await reject(
  () => adjustInventory(product, -2, '不可扣成負庫存'),
  /INSUFFICIENT_INVENTORY/,
  'manual inventory adjustment cannot make stock negative',
);
equal(Number((await db.query('select coalesce(sum(delta),0) quantity from spa_inventory_entries where product_id=$1', [product])).rows[0].quantity), quantityBeforeFailure, 'rejected inventory adjustment leaves the ledger unchanged');
await adjustInventory(product, -1, '售罄測試');
equal(Number((await db.query('select coalesce(sum(delta),0) quantity from spa_inventory_entries where product_id=$1', [product])).rows[0].quantity), 0, 'inventory may be adjusted exactly to zero');

await db.close();
console.log(`PASS: ${checks} product storefront, POS channel and inventory consistency assertions`);
