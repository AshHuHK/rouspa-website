import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { gatherStewardContext, validatePageAccess } from '../server/steward-context.mjs';

const now = new Date('2026-10-08T08:00:00Z'), range = { from: '2026-10-01', to: '2026-10-08' };
const owner = { role: 'owner', permissions: [], staff_id: 'PRIVATE_STAFF_ID' };
const worker = { role: 'therapist', permissions: ['dashboard.view', 'appointments.view', 'reviews.view'], staff_id: 'PRIVATE_STAFF_ID' };
const privateFields = { id: 'PRIVATE_RECORD_ID', staff_id: 'PRIVATE_STAFF_ID', name: 'PRIVATE_PERSON_NAME', customer_name: 'PRIVATE_CUSTOMER_NAME', phone: 'PRIVATE_PHONE_0912345678', email: 'PRIVATE_EMAIL@example.test', manage_token: 'PRIVATE_MANAGE_TOKEN', review_token: 'PRIVATE_REVIEW_TOKEN', comment: 'PRIVATE_REVIEW_COMMENT', reply: 'PRIVATE_REPLY', reason: 'PRIVATE_REASON', note: 'PRIVATE_NOTE', latitude: 23.4768128, longitude: 120.4431785, exact_location: 'PRIVATE_GEO', auth_user_id: 'PRIVATE_AUTH_ID', reference: 'PRIVATE_BOOKING_REFERENCE', website_content: { secret: 'PRIVATE_WEBSITE_DATA' } };
const row = value => ({ ...privateFields, ...value });
const fixtures = {
 spa_catalog: { settings: row({ opening_minute: 600, closing_minute: 1560, slot_minutes: 30, booking_days: 180, cancellation_hours: 24, auto_confirm: true }), business: privateFields, website: privateFields, business_hours: [row({ weekday: 0, is_open: true, opening_minute: 600, closing_minute: 1560 })], today_hours: row({ is_open: true, opening_minute: 600, closing_minute: 1560 }), services: [row({ name: '公開療程', duration_minutes: 90, buffer_minutes: 15, price_cents: 188000, member_price_cents: 168000, status: 'active', active: true, online_booking_enabled: true })], website_addons: [row({ name: '公開加購', duration_minutes: 15, price_cents: 30000 })], staff: [privateFields], skills: [privateFields] },
 spa_dashboard: row({ date: '2026-10-08', appointments: 12, pending: 2, completed: 5, cancelled: 1, staff_working: 3, rooms_active: 4, revenue_cents: 940000, new_members: 2, low_stock: 1, today_hours: row({ is_open: true, opening_minute: 600, closing_minute: 1560 }), next_appointments: [privateFields] }),
 spa_operations_convenience: { ...privateFields, today: '2026-10-08', edit_open: false, beds: [row({ state: 'free', overlap_count: 0, current: privateFields, next: privateFields }), row({ state: 'treatment', overlap_count: 2, current: privateFields })], todos: [row({ key: 'pending_bookings', count: 2, severity: 'urgent', module: 'bookings', context: privateFields, description: 'PRIVATE_DESCRIPTION' }), row({ key: 'payroll_drafts', count: 3, severity: 'normal', module: 'payroll' }), row({key:'completion',count:0,severity:'urgent',module:'bookings'}), row({ key: 'PRIVATE_BAD_KEY', count: 100, module: 'bookings' })] },
 spa_admin_bookings: [row({ therapist: '授權技師甲', status: 'completed', staff_change_count: 1, checkout: row({ revenue_cents: 188000 }) }), row({ therapist: '授權技師乙', staff_id: 'PRIVATE_OTHER_STAFF', status: 'completed', checkout: null }), row({ therapist: '授權技師甲', status: 'pending', checkout: null })],
 spa_customers_list: [row({ customer_type: 'member', status: 'active', balance_cents: 300050, visits: 3, no_shows: 1, total_spend_cents: 500000 }), row({ customer_type: 'guest', status: 'blocked', archived_at: null, balance_cents: 0, visits: 1, no_shows: 0, total_spend_cents: 100000 }), row({ customer_type: 'member', archived_at: '2026-09-01', balance_cents: 10000, visits: 0, no_shows: 0, total_spend_cents: 188000 })],
 spa_catalog_admin: { services: [row({ name: '公開療程', price_cents: 188000, duration_minutes: 90, status: 'active', active: true })], products: [row({ name: '公開商品', status: 'active', price_cents: 80000, member_price_cents: 70000, inventory: 2, low_stock_threshold: 3 })], staff: [privateFields], skills: [privateFields] },
 spa_team_os: { staff: [row({ name: '授權技師甲', job_title_id: 'PRIVATE_TITLE_ID', employment_status: 'active', active: true, archived_at: null }), row({ name: '授權技師乙', employment_status: 'departed', active: false }), row({ name: '授權技師丙', employment_status: 'inactive', archived_at: '2026-09-01' })], job_titles: [row({ id: 'PRIVATE_TITLE_ID', name: '調理師' })], shifts: [privateFields], daily_shifts: [privateFields], time_off: [privateFields], accounts: [row({ active: true })], compensation_profiles: [row({ base_pay_cents: 9000000 })] },
 spa_payroll_admin: { preview: [row({ employee: '授權技師甲', pay_basis: 'session', work_minutes: 480, service_minutes: 180, service_count: 2, base_pay_rate_cents: 50000, service_commission_bps: 1750, product_commission_bps: 500, total_cents: 240001, commission_eligibility_met: true, overtime_warning: 'PRIVATE_WARNING', calculation: privateFields })], rules: [row({ id: 'PRIVATE_RULE_ID', version_no: 3, status: 'active', effective_from: '2026-10-01', hourly_divisor: 240, monthly_overtime_limit_minutes: 2760, include_regular_commission: true }), row({ id: 'PRIVATE_FUTURE_RULE', version_no: 4, status: 'active', effective_from: '2027-01-01' })], rates: [row({ rule_version_id: 'PRIVATE_RULE_ID', employment_type_code: 'full_time', overtime_type: 'weekday', start_minute: 0, end_minute: 120, multiplier_bps: 13334 })], tiers: [row({ rule_version_id: 'PRIVATE_RULE_ID', job_title_name: '調理師', employment_type_code: 'full_time', metric: 'service_sales_cents', threshold_from: 100000, threshold_to: 300000, rate_bps: 1750, calculation_mode: 'progressive' })], compensation_profiles: [row({ active: true, job_title_name: '調理師', employment_type_code: 'full_time', pay_basis: 'session', base_pay_cents: 50000 })], time_entries: [row({ status: 'draft' })], overtime: [row({ status: 'draft' })], adjustments: [privateFields], runs: [row({ status: 'draft', calculation_snapshot: privateFields })] },
 spa_staff_self: { profile: row({ pay_basis: 'hourly', base_pay_cents: 20000, commission_bps: 1750 }), lifetime_completed: 20, metrics: row({ completed: 2, settled_completed: 1, unsettled_completed: 1, minutes: 90, work_minutes: 480, commission_cents: 40000, total_cents: 200001, rating: 4.5, reviews: 2, payroll_status: 'finalized' }), payroll: row({ pay_basis: 'hourly', base_pay_rate_cents: 20000, total_cents: 200001 }), reviews: [privateFields], shifts: [privateFields], daily_shifts: [privateFields], time_off: [privateFields] },
 spa_attendance_self: { settings: row({ max_shift_minutes: 1440, grace_minutes: 5, radius_m: 100, max_accuracy_m: 50 }), open: row({ status: 'open' }), rows: [row({ status: 'approved', effective_start: '2026-10-07T02:00:00Z', effective_end: '2026-10-07T10:00:59Z', break_minutes: 30 }), row({ status: 'pending', effective_start: '2026-10-08T02:00:00Z', effective_end: '2026-10-08T10:00:00Z', break_minutes: 0 })], requests: [row({ status: 'pending' })], events: [privateFields] },
 spa_report: row({ bookings: 3, completed: 2, cancelled: 0, no_show: 1, revenue_cents: 376001, cash_in_cents: 400000, cash_out_cents: 12000, wallet_liability_cents: 300050, cash_entries: [privateFields], staff: [row({ name: '授權技師甲', completed: 2, minutes: 180, revenue_cents: 376001, commission_cents: 50000 })], daily: [row({ date: '2026-10-07', net_cents: -12000 })], audit: [privateFields] }),
 spa_settings_os: { business: privateFields, website: privateFields, booking: row({ opening_minute: 600, closing_minute: 1560, booking_days: 180, slot_minutes: 30 }), resources: [row({ active: true }), row({ active: false })], business_hours: [row({ weekday: 0, is_open: true, opening_minute: 600, closing_minute: 1560 })], business_overrides: [row({ business_date: '2026-10-10', is_open: false, opening_minute: 600, closing_minute: 1560 })], assignment: row({ enabled: true, strategy: 'lowest_workload' }) },
 spa_reviews_admin: { reviews: [row({ rating: 5, status: 'published' }), row({ rating: 3, status: 'pending' })], feedback: [row({ message: 'PRIVATE_ANONYMOUS_FEEDBACK', status: 'unread' })] },
 spa_access_admin: { permissions: [row({ code: 'appointments.view', description: 'PRIVATE_PERMISSION_DESC' }), row({ code: 'dashboard.view' })], roles: [row({ code: 'therapist', active: true, permissions: ['appointments.view', 'PRIVATE_BAD_PERMISSION'] })] },
};
const zeros = keys => Object.fromEntries(keys.split(' ').map(key => [key, 0]));
const businessFixture = (session = owner, selectedRange = range) => ({
 schema_version: 1, scope: session.role === 'owner' ? 'store' : 'self', period: { ...selectedRange }, earliest_date: '2023-01-02', snapshot_date: '2026-10-08', units: { money: 'cents', time: 'minutes', timezone: 'Asia/Taipei' },
 source_contract: { aggregation: 'exact_all_authorized_records', appointments: 'business_date_actual_staff', sales: 'completed_unrefunded_appointment_services_and_paid_pos_net_lines', pos: 'taipei_paid_date_actual_selling_staff', attendance: 'approved_time_entries_floor_minutes', current: 'current_database_snapshot_not_period_totals', schedule: 'dated_overrides_not_inferred_weekly_coverage', refunds: 'checkout_refunded_date_and_cash_ledger;pos_refund_date_unavailable', customers: 'current_membership_and_archive_status;dormant_90_days_since_completed_or_paid_visit' },
 bookings: { ...zeros('total pending confirmed checked_in in_service completed cancelled no_show reassigned settled_completed unsettled_completed refunded_completed'), total: 9, completed: 3 },
 sales: { ...zeros('appointment_service_cents appointment_tea_cents pos_service_cents pos_product_cents pos_service_quantity pos_product_quantity service_minutes total_net_cents'), total_net_cents: 100050, service_minutes: 180 },
 staff: [row({ id: session.staff_id, name: '授權技師甲', title: '調理師', employment_status: 'active', active: true, ...zeros('completed settled_completed unsettled_completed refunded_completed service_minutes service_sales_cents product_sales_cents product_quantity pos_service_quantity reassigned reviews'), completed: 3, average_rating: null })],
 scheduling: zeros('daily_rows working_rows off_rows planned_minutes time_off_count requests_pending requests_approved requests_rejected submissions submitted_staff submission_months'),
 attendance: zeros('approved open pending rejected missing_clock_out requests_pending approved_work_minutes draft_time_entries approved_overtime_minutes draft_overtime_entries'),
 payroll: { status: 'preview', pending_sources: false, needs_recalculation: false, total_cents: 240001, rows: [row({ staff_id: session.staff_id, work_minutes: 480, service_minutes: 180, service_count: 3, total_cents: 240001, compensation_configured: true, commission_eligibility_met: true })] },
 ...(session.role === 'owner' ? { finances: zeros('cash_in_cents cash_out_cents cash_net_cents expenses_cents cash_refunds_cents checkout_refunds_cents checkout_refund_count pos_refunded_orders_by_paid_date'), customers: zeros('current_total current_active current_archived current_members current_guests new_in_period visited_in_period current_dormant_90_days'), current: zeros('wallet_liability_cents package_liability_cents active_staff departed_staff active_services active_products inventory_units') } : {}),
 private_payload: privateFields,
});
fixtures.spa_ai_business_snapshot = businessFixture();
const forbiddenTokens = ['PRIVATE_', '0912345678', '23.4768128', '120.4431785'];
function assertNoPrivateData(result) {
 const serialized = JSON.stringify(result);
 for (const token of forbiddenTokens) assert.ok(!serialized.includes(token), `Private data crossed model boundary: ${token}`);
 assert.ok(!/"[^"\s]*(?:_cents|_bps)"\s*:/.test(serialized), 'Unconverted money or percentage unit crossed boundary');
}
async function gather(page, session = owner, overrides = {}) {
 const calls = [];
 const result = await gatherStewardContext({ scope: 'page', session, page, range, now, rpc: async (name, args) => {
  calls.push({ name, args });
  if (Object.hasOwn(overrides, name)) { if (overrides[name] instanceof Error) throw overrides[name]; return overrides[name]; }
  assert.ok(Object.hasOwn(fixtures, name), `Unexpected read RPC: ${name}`);
  return structuredClone(fixtures[name]);
 } });
 assertNoPrivateData(result); return { ...result, calls };
}

// Authorization happens before even public reads. Owner-only screens remain
// unavailable to custom non-owner roles, matching Admin's actual navigation.
for (const page of ['dashboard', 'bookings', 'customers', 'pos', 'team', 'payroll', 'catalog', 'reviews', 'reports', 'access', 'settings', 'self']) assert.equal(validatePageAccess(owner, page), true);
assert.equal(validatePageAccess(worker, 'bookings'), true);
assert.equal(validatePageAccess(worker, 'self'), true);
assert.equal(validatePageAccess({ role: 'owner' }, 'self'), false);
for (const session of [null, {}, { role: null, permissions: ['dashboard.view'] }]) assert.equal(validatePageAccess(session, 'dashboard'), false);
for (const page of ['payroll', 'team', 'reports', 'access', 'settings', 'customers', 'catalog', 'pos', '__proto__', 'constructor', 'PRIVATE_UNKNOWN']) assert.equal(validatePageAccess({ ...worker, permissions: [...worker.permissions, 'payroll.view', 'settings.manage', 'customers.view'] }, page), false);
let anonymousReads = 0;
await assert.rejects(gatherStewardContext({ scope: 'page', session: null, page: 'dashboard', now, rpc: async () => { anonymousReads++; } }), error => error.code === 'FORBIDDEN' && error.status === 403);
assert.equal(anonymousReads, 0);
await assert.rejects(gatherStewardContext({ scope: 'page', session: owner, page: 'bookings', range: { from: '2026-02-30', to: '2026-03-01' }, now, rpc: async () => { anonymousReads++; } }), error => error.code === 'INVALID_DATE' && error.status === 400);

const dashboard = await gather('dashboard');
assert.equal(dashboard.state.dashboard.revenue_ntd, 9400);
assert.equal(dashboard.state.public_catalog.services[0].price_ntd, 1880);
assert.equal(dashboard.state.public_catalog.services[0].duration_minutes, 90);
assert.deepEqual(dashboard.state.operations.bed_counts, { free: 1, reserved: 0, treatment: 1, buffer: 0 });
assert.equal(dashboard.state.operations.overlapping_bed_count, 1);
assert.equal(dashboard.state.operations.active_todo_category_count,2);
assert.equal(dashboard.state.operations.todo_counts.completion,0);
assert.equal(dashboard.state.operations.todos.some(row=>row.count===0),false);
const staffDashboard = await gather('dashboard', worker);
assert.equal(staffDashboard.state.dashboard.revenue_ntd, undefined);
assert.deepEqual(staffDashboard.state.operations.todos.map(task => task.key), ['pending_bookings']);
const booked = await gather('bookings');
assert.equal(booked.state.bookings.completed_unsettled_count, 1);
assert.equal(booked.state.bookings.actual_staff_count, 2);
assert.deepEqual(booked.state.bookings.actual_staff[0], { staff: '技師 1', assigned: 2, completed: 1, reassigned: 1 });
assert.deepEqual(booked.calls.find(call => call.name === 'spa_admin_bookings').args, { p_from: range.from, p_to: range.to });
const staffBooked = await gather('bookings', worker);
assert.equal(staffBooked.state.bookings.completed_unsettled_count, undefined, 'Hidden checkout must not be labeled unpaid');
const members = await gather('customers');
assert.equal(members.state.customers.current, 2);
assert.equal(members.state.customers.wallet_balance_ntd, 3100.5);
assert.equal(members.state.customers.lifetime_service_spend_ntd, 7880);
const pos = await gather('pos');
assert.ok(pos.state.catalog && pos.state.customers);
const inventory = await gather('catalog');
assert.equal(inventory.state.catalog.products[0].price_ntd, 800);
assert.equal(inventory.state.catalog.products[0].inventory, 2);
assert.equal(inventory.state.catalog.low_stock_count, 1);
const people = await gather('team');
assert.deepEqual(people.state.team.titles, [{ title: '調理師', staff_count: 1 }]);
assert.equal(people.state.team.departed, 1);
assert.equal(people.state.team.active_account_count, 1);
const pay = await gather('payroll');
assert.deepEqual(pay.calls.find(call => call.name === 'spa_payroll_admin').args, { p_from: range.from, p_to: range.to, p_rule: null });
assert.equal(pay.state.payroll.active_rule.version_no, 3);
assert.equal(pay.state.payroll.preview_total_ntd, 2400.01);
assert.equal(pay.state.payroll.preview[0].pay_basis, 'session');
assert.equal(pay.state.payroll.preview[0].service_commission_percent, 17.5);
assert.equal(pay.state.payroll.preview[0].work_minutes, 480);
assert.equal(pay.state.payroll.overtime_rates[0].multiplier_percent, 133.34);
assert.deepEqual(pay.state.payroll.commission_tiers[0], { title: '調理師', employment_type: 'full_time', metric: 'service_sales_ntd', mode: 'progressive', threshold_from: 1000, threshold_to: 3000, rate_percent: 17.5 });
assert.equal(pay.state.payroll.compensation_profiles[0].base_pay_ntd, 500);
assert.equal(pay.state.payroll.draft_time_entry_count, 1);
assert.equal(pay.state.payroll.draft_overtime_count, 1);
const self = await gather('self', { role: 'therapist', permissions: [], staff_id: 'PRIVATE_STAFF_ID' });
assert.deepEqual(self.calls.map(call => call.name), ['spa_catalog', 'spa_staff_self', 'spa_attendance_self']);
assert.equal(self.state.self.metrics.total_ntd, 2000.01);
assert.equal(self.state.self.profile.commission_percent, 17.5);
assert.equal(self.state.attendance.approved_work_minutes, 450);
assert.equal(self.state.attendance.counts.pending, 1);
assert.deepEqual(self.state.attendance.settings, { max_shift_minutes: 1440, grace_minutes: 5, radius_m: 100, max_accuracy_m: 50 });
const report = await gather('reports');
assert.equal(report.state.reports.revenue_ntd, 3760.01);
assert.equal(report.state.reports.daily[0].net_ntd, -120);
const store = await gather('settings');
assert.equal(store.state.settings.active_resources_count, 1);
assert.equal(store.state.settings.booking.closing_minute, 1560);
assert.equal(store.state.settings.overrides[0].business_date, '2026-10-10');
const ratings = await gather('reviews', worker);
assert.equal(ratings.state.reviews.average_rating, 4);
assert.equal(ratings.state.reviews.status_counts.pending, 1);
assert.equal(ratings.state.reviews.feedback_count, 1);
const roles = await gather('access');
assert.deepEqual(roles.state.access.roles[0].permissions, ['appointments.view']);

const transient = await gather('bookings', owner, { spa_admin_bookings: new Error('PRIVATE_DB_ERROR_0912345678') });
assert.equal(transient.state.bookings, undefined);
assert.deepEqual(transient.failures, [{ rpc: 'spa_admin_bookings', label: '所選日期預約統計', code: 'READ_FAILED' }]);
const permissionErrors = [Object.assign(new Error('FORBIDDEN PRIVATE_DB_ERROR'), { code: 'P0001' }), Object.assign(new Error('PRIVATE_DB_ERROR'), { status: 403 }), Object.assign(new Error('permission denied'), { code: '42501' })];
for (const denial of permissionErrors) {
 const calls = [];
 await assert.rejects(gatherStewardContext({ scope: 'page', session: owner, page: 'payroll', range, now, rpc: async name => { calls.push(name); if (name === 'spa_dashboard') throw denial; return fixtures[name]; } }), error => error.status === 403 && error.code === 'FORBIDDEN');
 assert.deepEqual(calls, ['spa_catalog', 'spa_dashboard'], 'Permission failures must stop all further context reads');
}
const wrapped = await gather('reviews', worker, { spa_reviews_admin: { data: fixtures.spa_reviews_admin, error: null } });
assert.equal(wrapped.state.reviews.average_rating, 4);
await assert.rejects(gatherStewardContext({ scope: 'page', session: worker, page: 'reviews', range, now, rpc: async name => name === 'spa_catalog' ? { data: null, error: { status: 401 } } : fixtures[name] }), error => error.status === 401);

// Verify fixture shapes against the latest real SQL definitions, including the
// easy-to-confuse attendance row key, session pay basis and tier mode field.
const migrationDirectory = new URL('../supabase/migrations/', import.meta.url);
const sqlFiles = await readdir(migrationDirectory), definitions = new Map();
for (const file of sqlFiles.filter(file => file.endsWith('.sql')).sort()) {
 const sql = await readFile(new URL(file, migrationDirectory), 'utf8');
 for (const match of sql.matchAll(/create (?:or replace )?function public\.(spa_[a-z_]+)\(([^$]*?)\$\$([\s\S]*?)\$\$;/gi)) definitions.set(match[1], { declaration: match[2], body: match[3] });
}
for (const name of Object.keys(fixtures)) assert.ok(definitions.has(name), `Read RPC does not exist in migrations: ${name}`);
for (const [name, keys] of Object.entries({ spa_catalog: ['settings', 'services', 'website_addons', 'business_hours', 'today_hours'], spa_dashboard: ['appointments', 'revenue_cents', 'staff_working'], spa_operations_convenience: ['beds', 'todos', 'today'], spa_admin_bookings: ['staff_change_count', 'checkout', 'status'], spa_payroll_admin: ['preview', 'compensation_profiles', 'rules', 'rates', 'tiers'], spa_staff_self: ['profile', 'metrics', 'payroll', 'work_minutes', 'total_cents'], spa_report: ['revenue_cents', 'cash_entries', 'daily'], spa_settings_os: ['booking', 'resources', 'business_overrides'], spa_team_os: ['staff', 'job_titles', 'daily_shifts', 'accounts'], spa_reviews_admin: ['reviews', 'feedback'], spa_access_admin: ['roles', 'permissions'], spa_attendance_self: ['rows', 'open', 'requests', 'settings', 'events'] })) {
 for (const key of keys) assert.ok(definitions.get(name).body.includes(`'${key}'`), `Fixture field ${name}.${key} must match actual SQL`);
}
assert.match(definitions.get('spa_admin_bookings').declaration, /p_from date,p_to date/);
assert.match(definitions.get('spa_payroll_admin').declaration, /p_rule uuid default null/);
const attendanceSql = await readFile(new URL('202610060001_employee_attendance.sql', migrationDirectory), 'utf8');
for (const key of ['effective_start', 'effective_end', 'break_minutes', 'radius_m', 'max_shift_minutes', 'grace_minutes']) assert.ok(attendanceSql.includes(key));
const policySql = await readFile(new URL('202610040002_payroll_policy_engine.sql', migrationDirectory), 'utf8');
assert.ok(policySql.includes('calculation_mode'));
const compensationSql = await readFile(new URL('202610040001_compensation_pos_titles.sql', migrationDirectory), 'utf8');
assert.ok(compensationSql.includes("pay_basis in ('monthly','hourly','session')"));

async function gatherBusiness({ session = owner, selectedRange = range, selectedPeriod, overrides = {}, maxConcurrent = 3 } = {}) {
 const calls = []; let concurrent = 0, peak = 0;
 const result = await gatherStewardContext({ session, page: 'dashboard', range: selectedRange, period: selectedPeriod, now, rpc: async (name, args) => {
  calls.push({ name, args }); concurrent++; peak = Math.max(peak, concurrent);
  try {
   await new Promise(resolve => setTimeout(resolve, 2));
   if (Object.hasOwn(overrides, name)) { if (overrides[name] instanceof Error) throw overrides[name]; return structuredClone(overrides[name]); }
   if (name === 'spa_ai_business_snapshot') return businessFixture(session, selectedPeriod === 'all' ? { from: '2023-01-02', to: selectedRange.to } : selectedRange);
   return structuredClone(fixtures[name]);
  } finally { concurrent--; }
 } });
 assert.ok(peak <= maxConcurrent); assertNoPrivateData(result); return { ...result, calls, peak };
}
const wholeBusiness = await gatherBusiness();
assert.equal(wholeBusiness.state.scope, 'business', 'Business context is the default');
assert.equal(wholeBusiness.peak, 3, 'Independent business reads run in the bounded pool');
assert.deepEqual(new Set(wholeBusiness.calls.map(call => call.name)), new Set(Object.keys(fixtures)), 'Owner receives every authorized read summary regardless dashboard tab');
assert.equal(wholeBusiness.sources.length, Object.keys(fixtures).length, 'No valid source disappears behind a UI or API cap');
assert.equal(wholeBusiness.state.business_snapshot.sales.total_net_ntd, 1000.5);
assert.equal(wholeBusiness.state.business_snapshot.payroll.rows[0].staff, '授權技師甲');
assert.equal(wholeBusiness.state.business_snapshot.payroll.rows[0].title, '調理師');
assert.equal(wholeBusiness.state.business_snapshot.payroll.rows[0].commission_eligibility_met, true);
assert.equal(wholeBusiness.state.payroll.preview[0].staff, '授權技師甲');
assert.equal(wholeBusiness.state.reports.staff[0].staff, '授權技師甲');
assert.equal(wholeBusiness.state.bookings.actual_staff[0].staff, '授權技師甲');
assert.equal(wholeBusiness.state.source_periods.dashboard.basis, 'current_taipei_day');
assert.equal(wholeBusiness.state.source_periods.reports.basis, 'taipei_recorded_payments_and_refunds');
assert.equal(wholeBusiness.state.source_periods.customers.basis, 'current_and_lifetime');
const ownBusiness = await gatherBusiness({ session: worker });
assert.deepEqual(ownBusiness.calls.map(call => call.name).sort(), ['spa_ai_business_snapshot', 'spa_catalog', 'spa_dashboard', 'spa_operations_convenience', 'spa_staff_self', 'spa_attendance_self'].sort());
assert.equal(ownBusiness.state.business_snapshot.scope, 'self');
assert.equal(ownBusiness.state.business_snapshot.staff[0].name, '本人');
for (const key of ['customers', 'finances', 'current']) assert.equal(ownBusiness.state.business_snapshot[key], undefined);
for (const key of ['customers', 'catalog', 'reports', 'payroll', 'team', 'access', 'reviews']) assert.equal(ownBusiness.state[key], undefined);
const noOwnProfile = await gatherBusiness({ session: { role: 'receptionist', permissions: ['dashboard.view'], staff_id: null } });
assert.deepEqual(noOwnProfile.calls.map(call => call.name), ['spa_catalog', 'spa_dashboard', 'spa_operations_convenience']);
assert.equal(noOwnProfile.state.business_snapshot, undefined);
assert.equal(noOwnProfile.state.self, undefined);
assert.equal(noOwnProfile.state.attendance, undefined);
assert.ok(noOwnProfile.failures.some(failure => failure.code === 'OWN_PROFILE_REQUIRED'));
assert.deepEqual(noOwnProfile.state.availability, [{ module: 'business_snapshot', status: 'own_profile_required' }]);
assert.equal(noOwnProfile.state.dashboard.revenue_ntd, undefined);
const manyYears = { from: '2020-01-01', to: range.to };
const longBusiness = await gatherBusiness({ selectedRange: manyYears });
assert.deepEqual(longBusiness.resolvedRange, manyYears);
assert.equal(longBusiness.state.business_snapshot.bookings.total, 9);
for (const rpcName of ['spa_admin_bookings', 'spa_report', 'spa_payroll_admin', 'spa_staff_self', 'spa_attendance_self']) {
 assert.ok(!longBusiness.calls.some(call => call.name === rpcName), 'Legacy RPC must never receive an overlong period');
 assert.ok(longBusiness.failures.some(failure => failure.rpc === rpcName && failure.code === 'RANGE_NOT_SUPPORTED'));
}
const allBusiness = await gatherBusiness({ selectedRange: { from: '1900-01-01', to: range.to }, selectedPeriod: 'all' });
assert.deepEqual(allBusiness.calls[0].args, { p_from: null, p_to: range.to });
assert.deepEqual(allBusiness.resolvedRange, { from: '2023-01-02', to: range.to });
assert.deepEqual(allBusiness.state.range, allBusiness.resolvedRange);
const otherScope = businessFixture(); otherScope.scope = 'self';
await assert.rejects(gatherBusiness({ overrides: { spa_ai_business_snapshot: otherScope } }), error => error.status === 403);
await assert.rejects(gatherBusiness({ session: worker, overrides: { spa_ai_business_snapshot: businessFixture() } }), error => error.status === 403);
const otherPerson = businessFixture(worker); otherPerson.staff[0].id = 'PRIVATE_OTHER_PERSON';
await assert.rejects(gatherBusiness({ session: worker, overrides: { spa_ai_business_snapshot: otherPerson } }), error => error.status === 403);
const wrongPeriod = businessFixture(); wrongPeriod.period.from = '2026-09-01';
await assert.rejects(gatherBusiness({ overrides: { spa_ai_business_snapshot: wrongPeriod } }), error => error.status === 403);
for (const malformed of [{}, null, 'PRIVATE_BAD_SNAPSHOT', { ...businessFixture(), units: { money: 'NTD', time: 'minutes', timezone: 'Asia/Taipei' } }]) {
 const result = await gatherBusiness({ overrides: { spa_ai_business_snapshot: malformed } });
 assert.equal(result.state.business_snapshot, undefined);
 assert.ok(result.failures.some(failure => failure.rpc === 'spa_ai_business_snapshot' && failure.code === 'READ_FAILED'));
}
const permissionChanged = Object.assign(new Error('FORBIDDEN'), { status: 403 });
await assert.rejects(gatherBusiness({ overrides: { spa_dashboard: permissionChanged } }), error => error.status === 403);

const rpcPages = { spa_catalog: 'dashboard', spa_dashboard: 'dashboard', spa_operations_convenience: 'dashboard', spa_admin_bookings: 'bookings', spa_customers_list: 'customers', spa_catalog_admin: 'catalog', spa_team_os: 'team', spa_payroll_admin: 'payroll', spa_staff_self: 'self', spa_attendance_self: 'self', spa_report: 'reports', spa_settings_os: 'settings', spa_reviews_admin: 'reviews', spa_access_admin: 'access' };
for (const [rpcName, page] of Object.entries(rpcPages)) {
 for (const malformed of [{}, null, 'PRIVATE_UNEXPECTED_BODY', ['PRIVATE_WRONG_ROW']]) {
  const result = await gather(page, owner, { [rpcName]: malformed });
  assert.ok(result.failures.some(failure => failure.rpc === rpcName && failure.code === 'READ_FAILED'), `${rpcName} must not turn malformed data into zero totals`);
  const good = await gather(page);
  const failedLabel = result.failures.find(failure => failure.rpc === rpcName).label;
  assert.ok(good.sources.some(source => source.label === failedLabel));
  assert.ok(!result.sources.some(source => source.label === failedLabel), 'A failed read must not appear as a successful source');
 }
}
for (const key of ['preview', 'rules', 'time_entries', 'overtime', 'runs']) {
 const bad = structuredClone(fixtures.spa_payroll_admin); delete bad[key];
 const result = await gather('payroll', owner, { spa_payroll_admin: bad });
 assert.equal(result.state.payroll, undefined, `Missing payroll ${key} must omit all payroll state`);
}
for (const key of ['rows', 'requests']) {
 const bad = structuredClone(fixtures.spa_attendance_self); delete bad[key];
 const result = await gather('self', owner, { spa_attendance_self: bad });
 assert.equal(result.state.attendance, undefined, `Missing attendance ${key} must not produce zero work`);
}

// Execute the actual migrations and read functions. No mock schema or fake
// return shape stands between this integration test and the model boundary.
const db = new PGlite();
try {
 await db.exec(`create role anon;create role authenticated;create role service_role;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
 for (const file of sqlFiles.filter(file => file.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(file, migrationDirectory), 'utf8'));
 const realOwner = randomUUID(), employee = randomUUID(), outsider = randomUUID();
 await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)', [realOwner, 'PRIVATE_OWNER@example.test', employee, 'PRIVATE_EMPLOYEE@example.test', outsider, 'PRIVATE_OUTSIDER@example.test']);
 const staff = (await db.query("select id from spa_staff where active and employment_status='active' and archived_at is null order by display_order limit 2")).rows;
 assert.equal(staff.length, 2);
 await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',$2,null),($3,'therapist',$4,'steward_test_employee')", [realOwner, staff[0].id, employee, staff[1].id]);
 const customer = (await db.query("insert into spa_customers(name,phone,customer_type,notes) values('PRIVATE_CUSTOMER_NAME','0999099998','member','PRIVATE_CUSTOMER_NOTES') returning id")).rows[0].id;
 const realService = (await db.query("select id,name,duration_minutes,price_cents from spa_services where active and online_booking_enabled order by display_order limit 1")).rows[0];
 const roomId = (await db.query('select id from spa_rooms where active order by name limit 1')).rows[0].id;
 const bookingId = (await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,note)
 values($1,$2,$3,$4,$5,'2026-10-07','2026-10-07T10:00:00+08:00','2026-10-07T12:00:00+08:00','2026-10-07T12:15:00+08:00','completed',$6,$7,'PRIVATE_BOOKING_NOTE') returning id`, [randomUUID(), customer, staff[1].id, roomId, realService.id, realService.name, realService.price_cents])).rows[0].id;
 await db.query("insert into spa_reviews(appointment_id,rating,comment,reply) values($1,4,'PRIVATE_REVIEW_COMMENT','PRIVATE_REPLY')", [bookingId]);
 await db.query("insert into spa_feedback(message) values('PRIVATE_ANONYMOUS_FEEDBACK')");
 await db.query("insert into spa_time_entries(staff_id,work_date,started_at,ended_at,status,note) values($1,'2026-10-07','2026-10-07T10:00:00+08:00','2026-10-07T18:00:00+08:00','draft','PRIVATE_TIME_NOTE')", [staff[1].id]);
 await db.query("insert into spa_overtime_entries(staff_id,work_date,overtime_type,minutes,status,reason) values($1,'2026-10-07','weekday',60,'draft','PRIVATE_OVERTIME_REASON')", [staff[1].id]);
 await db.query("insert into spa_attendance(staff_id,work_date,clock_in,clock_out,effective_start,effective_end,break_minutes,status,review_note) values($1,'2026-10-07','2026-10-07T10:00:00+08:00','2026-10-07T18:00:59+08:00','2026-10-07T10:00:00+08:00','2026-10-07T18:00:59+08:00',30,'approved','PRIVATE_ATTENDANCE_NOTE')", [staff[1].id]);
 let rpcQueue = Promise.resolve();
 function realRpc(user, name, args = {}) {
  // A single PGlite connection serializes transactions; production Supabase
  // performs these independent bound-JWT reads through separate HTTP requests.
  const result = rpcQueue.then(() => readRealRpc(user, name, args));
  rpcQueue = result.catch(() => {}); return result;
 }
 async function readRealRpc(user, name, args = {}) {
  assert.ok(/^spa_[a-z_]+$/.test(name));
  await db.exec('begin');
  try {
   await db.exec(`set local role ${user ? 'authenticated' : 'anon'}`);
   await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)", [user || '', JSON.stringify({ iat: Math.floor(Date.now() / 1000) + 60 })]);
   const keys = Object.keys(args); assert.ok(keys.every(key => /^p_[a-z_]+$/.test(key)));
   const result = (await db.query(`select public.${name}(${keys.map((key, index) => `${key}=>$${index + 1}`).join(',')}) result`, Object.values(args))).rows[0].result;
   await db.exec('commit'); return result;
  } catch (error) { await db.exec('rollback'); throw error; }
 }
 const ownerSession = await realRpc(realOwner, 'spa_session'), employeeSession = await realRpc(employee, 'spa_session');
 for (const page of ['dashboard', 'bookings', 'customers', 'pos', 'team', 'payroll', 'catalog', 'reviews', 'reports', 'access', 'settings', 'self']) {
  const result = await gatherStewardContext({ scope: 'page', session: ownerSession, page, range, now, rpc: (name, args) => realRpc(realOwner, name, args) });
  assert.deepEqual(result.failures, [], `Actual owner ${page} RPCs must all pass shape validation`);
  assertNoPrivateData(result);
  assert.ok(!JSON.stringify(result).includes('0999099998'), 'Customer phone must never enter context');
  if (page === 'payroll') { assert.equal(result.state.payroll.draft_time_entry_count, 1); assert.equal(result.state.payroll.draft_overtime_count, 1); }
  if (page === 'bookings') assert.equal(result.state.bookings.status_counts.completed, 1);
  if (page === 'reviews') assert.equal(result.state.reviews.average_rating, 4);
 }
 for (const page of ['dashboard', 'bookings', 'reviews', 'self']) {
  const result = await gatherStewardContext({ scope: 'page', session: employeeSession, page, range, now, rpc: (name, args) => realRpc(employee, name, args) });
  assert.deepEqual(result.failures, [], `Actual employee ${page} RPCs must all succeed`); assertNoPrivateData(result);
  if (page === 'self') { assert.equal(result.state.attendance.approved_work_minutes, 450); assert.equal(result.state.attendance.settings.radius_m, 100); }
 }
 const realStoreBusiness = await gatherStewardContext({ session: ownerSession, page: 'dashboard', range, now, rpc: (name, args) => realRpc(realOwner, name, args) });
 assert.deepEqual(realStoreBusiness.failures, [], 'Every owner business source validates against actual RPC data');
 assert.equal(realStoreBusiness.sources.length, Object.keys(fixtures).length);
 assert.equal(realStoreBusiness.state.business_snapshot.scope, 'store');
 assert.equal(realStoreBusiness.state.business_snapshot.bookings.total, 1);
 assert.equal(realStoreBusiness.state.business_snapshot.bookings.completed, 1);
 assert.equal(realStoreBusiness.state.business_snapshot.attendance.draft_time_entries, 1);
 assert.equal(realStoreBusiness.state.business_snapshot.payroll.pending_sources, true);
 const actualNames = (await db.query('select name from spa_staff')).rows.map(row => row.name);
 assert.ok(actualNames.includes(realStoreBusiness.state.business_snapshot.staff[0].name));
 assert.ok(realStoreBusiness.state.business_snapshot.payroll.rows.every(row => actualNames.includes(row.staff)));
 assertNoPrivateData(realStoreBusiness);
 const realOwnBusiness = await gatherStewardContext({ session: employeeSession, page: 'dashboard', range, now, rpc: (name, args) => realRpc(employee, name, args) });
 assert.deepEqual(realOwnBusiness.failures, []);
 assert.equal(realOwnBusiness.state.business_snapshot.scope, 'self');
 assert.equal(realOwnBusiness.state.business_snapshot.staff.length, 1);
 assert.equal(realOwnBusiness.state.business_snapshot.staff[0].name, '本人');
 assert.equal(realOwnBusiness.state.business_snapshot.customers, undefined);
 assert.equal(realOwnBusiness.state.customers, undefined);
 assert.equal(realOwnBusiness.state.reports, undefined);
 assert.equal(realOwnBusiness.state.payroll, undefined);
 assertNoPrivateData(realOwnBusiness);
 await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,note)
 values($1,$2,$3,$4,$5,'2023-01-02','2023-01-02T10:00:00+08:00','2023-01-02T12:00:00+08:00','2023-01-02T12:15:00+08:00','pending',$6,$7,'PRIVATE_HISTORICAL_NOTE')`, [randomUUID(), customer, staff[1].id, roomId, realService.id, realService.name, realService.price_cents]);
 for (const [user, session] of [[realOwner, ownerSession], [employee, employeeSession]]) {
  const multiYear = await gatherStewardContext({ session, page: 'dashboard', range: { from: '2020-01-01', to: range.to }, now, rpc: (name, args) => realRpc(user, name, args) });
  assert.equal(multiYear.state.business_snapshot.bookings.total, 2, 'Historical period totals come from exact unbounded aggregation');
  assert.equal(multiYear.state.business_snapshot.payroll.status, 'unsupported_range');
  assert.equal(multiYear.state.business_snapshot.payroll.total_ntd, undefined, 'Unsupported salary estimation is unavailable, never zero');
  assert.ok(multiYear.failures.every(failure => failure.code === 'RANGE_NOT_SUPPORTED'));
  assertNoPrivateData(multiYear);
  const allHistory = await gatherStewardContext({ session, page: 'dashboard', period: 'all', range: { from: '1900-01-01', to: range.to }, now, rpc: (name, args) => realRpc(user, name, args) });
  assert.deepEqual(allHistory.resolvedRange, { from: '2023-01-02', to: range.to }, 'All-history resolver returns actual authorized earliest date');
  assert.deepEqual(allHistory.state.range, allHistory.resolvedRange);
  assert.equal(allHistory.state.business_snapshot.bookings.total, 2);
  assertNoPrivateData(allHistory);
 }
 const outsiderSession = await realRpc(outsider, 'spa_session');
 await assert.rejects(gatherStewardContext({ scope: 'page', session: outsiderSession, page: 'dashboard', range, now, rpc: (name, args) => realRpc(outsider, name, args) }), error => error.status === 403);
 await assert.rejects(realRpc(null, 'spa_admin_bookings', { p_from: range.from, p_to: range.to }), /permission denied|FORBIDDEN/);
} finally { await db.close(); }
console.log('Steward context passed all-page real PGlite RPC integration, authorization, malformed-source rejection, unit conversion and private-data boundary checks.');
