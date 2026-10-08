import { taipeiDate, validRange } from '../src/lib/date-range.js';

const pages = Object.freeze({ dashboard: '營運首頁', bookings: '預約與日程', customers: '會員與儲值金', pos: '門店 POS', team: '人員與排班', payroll: '薪資與提成', catalog: '服務・商品・庫存', reviews: '評價', reports: '經營報表', access: '角色與權限', settings: '系統設定', self: '我的薪資與績效' });
const pagePermissions = { dashboard: 'dashboard.view', bookings: 'appointments.view', reviews: 'reviews.view' };
const has = (session, permission) => session?.role === 'owner' || (Array.isArray(session?.permissions) && session.permissions.includes(permission));
const list = value => Array.isArray(value) ? value.filter(row => row && typeof row === 'object' && !Array.isArray(row)) : [];
const number = value => (typeof value === 'number' || (typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value))) && Number.isFinite(Number(value)) ? Number(value) : undefined;
const label = value => typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 64) : undefined;
const code = value => typeof value === 'string' && /^[a-z][a-z0-9_.-]{0,63}$/.test(value) ? value : undefined;
const date = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : undefined;
const enumValue = (value, choices) => choices.includes(value) ? value : undefined;
const bool = value => typeof value === 'boolean' ? value : undefined;
const round = value => Math.round((value + Number.EPSILON) * 100) / 100;
const sum = (rows, key) => rows.reduce((total, row) => total + (number(row[key]) ?? 0), 0);

// This projection deliberately never spreads a database row. Unknown fields,
// nested records and arbitrary strings in numeric fields cannot cross this boundary.
function numericFields(row, keys) {
 const result = {};
 for (const key of keys) {
  const value = number(row?.[key]);
  if (value === undefined) continue;
  if (key.endsWith('_cents')) result[key.replace(/_cents$/, '_ntd')] = round(value / 100);
  else if (key.endsWith('_bps')) result[key.replace(/_bps$/, '_percent')] = round(value / 100);
  else result[key] = value;
 }
 return result;
}
function counted(rows, key, choices) {
 return Object.fromEntries(choices.map(value => [value, rows.filter(row => row[key] === value).length]));
}
function hours(row) {
 return { ...numericFields(row, ['weekday', 'opening_minute', 'closing_minute']), is_open: bool(row?.is_open), business_date: date(row?.business_date) };
}
function bookingSettings(row) {
 return { ...numericFields(row, ['opening_minute', 'closing_minute', 'slot_minutes', 'booking_days', 'cancellation_hours']), auto_confirm: bool(row?.auto_confirm), timezone: 'Asia/Taipei', currency: 'TWD' };
}
function services(rows) {
 return list(rows).slice(0, 40).map(row => ({ name: label(row.name), ...numericFields(row, ['duration_minutes', 'buffer_minutes', 'price_cents', 'member_price_cents']), active: bool(row.active), status: enumValue(row.status, ['active', 'draft', 'archived']), online_booking_enabled: bool(row.online_booking_enabled), website_visible: bool(row.website_visible) }));
}
function catalog(data) {
 return { booking: bookingSettings(data?.settings), business_hours: list(data?.business_hours).slice(0, 7).map(hours), today_hours: hours(data?.today_hours), services: services(data?.services), addons: services(data?.website_addons), publicly_bookable_staff_count: list(data?.staff).length };
}
function dashboard(data, session) {
 return { date: date(data?.date), ...numericFields(data, ['appointments', 'pending', 'completed', 'cancelled', 'staff_working', 'rooms_active']), ...(session.role === 'owner' ? numericFields(data, ['revenue_cents', 'new_members', 'low_stock']) : {}), today_hours: hours(data?.today_hours) };
}
const todoKeys = ['pending_bookings', 'arrivals', 'completion', 'unsettled', 'attendance', 'corrections', 'missing_clockout', 'schedule_requests', 'missing_schedule', 'payroll_drafts', 'low_stock', 'reviews', 'my_schedule', 'my_clockout', 'my_attendance', 'my_requests', 'my_submission'];
function convenience(data, session) {
 const beds = list(data?.beds), todos = list(data?.todos);
 return { today: date(data?.today), bed_counts: counted(beds, 'state', ['free', 'reserved', 'treatment', 'buffer']), overlapping_bed_count: beds.filter(row => (number(row.overlap_count) ?? 0) > 1).length,
  todos: todos.filter(row => todoKeys.includes(row.key) && validatePageAccess(session, row.module)).map(row => ({ key: row.key, count: number(row.count), severity: enumValue(row.severity, ['urgent', 'normal', 'waiting']), module: row.module })), next_month_self_edit_open: bool(data?.edit_open) };
}
const bookingStatuses = ['pending', 'confirmed', 'checked_in', 'in_service', 'completed', 'cancelled', 'no_show'];
function bookings(data, session) {
 const rows = list(data), byStaff = new Map();
 for (const row of rows) {
  if (typeof row.staff_id !== 'string') continue;
  if (!byStaff.has(row.staff_id)) byStaff.set(row.staff_id, { staff: `技師 ${byStaff.size + 1}`, assigned: 0, completed: 0, reassigned: 0 });
  const staff = byStaff.get(row.staff_id); staff.assigned++; if (row.status === 'completed') staff.completed++; if ((number(row.staff_change_count) ?? 0) > 0) staff.reassigned++;
 }
 return { count: rows.length, status_counts: counted(rows, 'status', bookingStatuses), actual_staff: [...byStaff.values()].slice(0, 40), actual_staff_count: byStaff.size, reassigned_count: rows.filter(row => (number(row.staff_change_count) ?? 0) > 0).length,
  // Without finance visibility a null checkout means hidden, not uncollected.
  ...(has(session, 'finance.view') ? { completed_unsettled_count: rows.filter(row => row.status === 'completed' && !row.checkout).length } : {}) };
}
function customers(data) {
 const rows = list(data), active = rows.filter(row => !row.archived_at);
 return { total: rows.length, current: active.length, archived: rows.length - active.length, members: active.filter(row => row.customer_type === 'member').length, guests: active.filter(row => row.customer_type === 'guest').length, blocked: active.filter(row => row.status === 'blocked').length, wallet_balance_ntd: round(sum(rows, 'balance_cents') / 100), completed_visits: sum(active, 'visits'), no_shows: sum(active, 'no_shows'), lifetime_service_spend_ntd: round(sum(rows, 'total_spend_cents') / 100) };
}
function adminCatalog(data) {
 const products = list(data?.products), serviceRows = list(data?.services);
 return { service_count: serviceRows.length, service_status_counts: counted(serviceRows, 'status', ['active', 'draft', 'archived']), services: services(serviceRows), product_count: products.length, low_stock_count: products.filter(row => row.status === 'active' && number(row.inventory) !== undefined && number(row.low_stock_threshold) !== undefined && Number(row.inventory) <= Number(row.low_stock_threshold)).length,
  products: products.slice(0, 40).map(row => ({ name: label(row.name), status: enumValue(row.status, ['active', 'draft', 'archived']), ...numericFields(row, ['price_cents', 'member_price_cents', 'inventory', 'low_stock_threshold']) })) };
}
function team(data) {
 const staff = list(data?.staff), titles = list(data?.job_titles);
 return { staff_count: staff.length, active: staff.filter(row => row.active && row.employment_status === 'active' && !row.archived_at).length, departed: staff.filter(row => row.employment_status === 'departed').length, archived: staff.filter(row => !!row.archived_at).length,
  titles: titles.slice(0, 24).map(title => ({ title: label(title.name), staff_count: staff.filter(row => row.job_title_id === title.id).length })), weekly_shift_count: list(data?.shifts).length, daily_shift_count: list(data?.daily_shifts).length, time_off_count: list(data?.time_off).length, active_account_count: list(data?.accounts).filter(row => row.active).length };
}
const wageFields = ['base_pay_rate_cents', 'work_minutes', 'completed_count', 'service_count', 'unsettled_completed_count', 'refunded_service_count', 'service_minutes', 'service_sales_cents', 'product_sales_cents', 'service_commission_bps', 'product_commission_bps', 'designated_bonus_bps', 'minimum_attendance_minutes', 'commission_start_service_minutes', 'overtime_minutes', 'base_cents', 'service_commission_cents', 'product_commission_cents', 'designated_bonus_cents', 'overtime_cents', 'bonus_cents', 'allowance_cents', 'deduction_cents', 'total_cents'];
function wage(row) {
 return { pay_basis: enumValue(row?.pay_basis, ['monthly', 'hourly', 'session']), ...numericFields(row, wageFields), commission_eligibility_met: bool(row?.commission_eligibility_met), has_overtime_warning: typeof row?.overtime_warning === 'string' && !!row.overtime_warning, has_commission_warning: typeof row?.commission_warning === 'string' && !!row.commission_warning };
}
function payroll(data, range) {
 const preview = list(data?.preview), rules = list(data?.rules);
 const current = rules.filter(row => row.status === 'active' && date(row.effective_from) && row.effective_from <= range.to).sort((a, b) => b.effective_from.localeCompare(a.effective_from) || (number(b.version_no) ?? 0) - (number(a.version_no) ?? 0))[0];
 const matches = row => !!current && row.rule_version_id === current.id;
 return { preview_staff_count: preview.length, preview_total_ntd: round(sum(preview, 'total_cents') / 100), preview: preview.slice(0, 24).map((row, index) => ({ staff: `人員 ${index + 1}`, ...wage(row) })), preview_rows_omitted: Math.max(0, preview.length - 24),
  active_rule: current ? { ...numericFields(current, ['version_no', 'hourly_divisor', 'monthly_overtime_limit_minutes', 'agreed_monthly_limit_minutes', 'quarterly_overtime_limit_minutes']), effective_from: date(current.effective_from), include_regular_commission: bool(current.include_regular_commission) } : null,
  compensation_profiles: list(data?.compensation_profiles).filter(row => row.active).slice(0, 24).map(row => ({ title: label(row.job_title_name), employment_type: code(row.employment_type_code), pay_basis: enumValue(row.pay_basis, ['monthly', 'hourly', 'session']), ...numericFields(row, ['base_pay_cents', 'service_commission_bps', 'product_commission_bps', 'designated_client_bonus_bps', 'minimum_attendance_minutes', 'commission_start_service_minutes']) })),
  overtime_rates: list(data?.rates).filter(matches).slice(0, 24).map(row => ({ employment_type: code(row.employment_type_code), overtime_type: enumValue(row.overtime_type, ['weekday', 'rest_day', 'national_holiday', 'regular_holiday']), ...numericFields(row, ['start_minute', 'end_minute', 'multiplier_bps']) })),
  commission_tiers: list(data?.tiers).filter(matches).slice(0, 32).map(row => {
   const monetary = ['service_sales_cents', 'product_sales_cents'].includes(row.metric), threshold = numericFields(row, ['threshold_from', 'threshold_to']);
   return { title: label(row.job_title_name), employment_type: code(row.employment_type_code), metric: enumValue(row.metric, ['service_minutes', 'service_count', 'service_sales_cents', 'product_sales_cents'])?.replace(/_cents$/, '_ntd'), mode: enumValue(row.calculation_mode, ['progressive', 'flat']), threshold_from: monetary && threshold.threshold_from !== undefined ? round(threshold.threshold_from / 100) : threshold.threshold_from, threshold_to: monetary && threshold.threshold_to !== undefined ? round(threshold.threshold_to / 100) : threshold.threshold_to, ...numericFields(row, ['rate_bps']) };
  }), draft_time_entry_count: list(data?.time_entries).filter(row => row.status === 'draft').length, draft_overtime_count: list(data?.overtime).filter(row => row.status === 'draft').length, payroll_run_counts: counted(list(data?.runs), 'status', ['draft', 'finalized']) };
}
function ownSelf(data) {
 return { profile: data?.profile ? { pay_basis: enumValue(data.profile.pay_basis, ['monthly', 'hourly', 'session']), ...numericFields(data.profile, ['base_pay_cents', 'commission_bps', 'product_commission_bps', 'designated_client_bonus_bps']) } : null, ...numericFields(data, ['lifetime_completed']), metrics: { ...numericFields(data?.metrics, ['completed', 'settled_completed', 'unsettled_completed', 'minutes', 'work_minutes', 'commission_cents', 'total_cents', 'rating', 'reviews']), payroll_status: enumValue(data?.metrics?.payroll_status, ['preview', 'finalized']) }, payroll: data?.payroll ? wage(data.payroll) : null, weekly_shift_count: list(data?.shifts).length, daily_shift_count: list(data?.daily_shifts).length, time_off_count: list(data?.time_off).length };
}
function ownAttendance(data) {
 const rows = list(data?.rows);
 const approvedMinutes = rows.filter(row => row.status === 'approved').reduce((total, row) => {
  const started = Date.parse(row.effective_start), ended = Date.parse(row.effective_end);
  return total + (Number.isFinite(started) && Number.isFinite(ended) ? Math.max(0, Math.floor((ended - started) / 60000) - (number(row.break_minutes) ?? 0)) : 0);
 }, 0);
 return { counts: counted(rows, 'status', ['open', 'pending', 'approved', 'rejected']), currently_clocked_in: data?.open?.status === 'open', request_counts: counted(list(data?.requests), 'status', ['pending', 'approved', 'rejected']), approved_work_minutes: approvedMinutes, settings: numericFields(data?.settings, ['max_shift_minutes', 'grace_minutes', 'radius_m', 'max_accuracy_m']) };
}
function reports(data) {
 return { ...numericFields(data, ['bookings', 'completed', 'cancelled', 'no_show', 'service_revenue_cents', 'pos_revenue_cents', 'revenue_cents', 'cash_in_cents', 'cash_out_cents', 'expenses_cents', 'wallet_liability_cents', 'package_liability_cents']), cash_entry_count: list(data?.cash_entries).length,
  staff: list(data?.staff).slice(0, 24).map((row, index) => ({ staff: `技師 ${index + 1}`, ...numericFields(row, ['completed', 'minutes', 'revenue_cents', 'commission_cents', 'rating', 'reviews']) })), daily: list(data?.daily).slice(0, 31).map(row => ({ date: date(row.date), ...numericFields(row, ['net_cents']) })) };
}
function settings(data) {
 return { booking: bookingSettings(data?.booking), business_hours: list(data?.business_hours).slice(0, 7).map(hours), overrides: list(data?.business_overrides).slice(0, 24).map(hours), resources_count: list(data?.resources).length, active_resources_count: list(data?.resources).filter(row => row.active).length, automatic_assignment_enabled: bool(data?.assignment?.enabled), assignment_strategy: enumValue(data?.assignment?.strategy, ['lowest_workload', 'round_robin']) };
}
function reviews(data) {
 const rows = list(data?.reviews), ratings = rows.map(row => number(row.rating)).filter(value => value >= 1 && value <= 5);
 return { count: rows.length, status_counts: counted(rows, 'status', ['pending', 'published', 'hidden', 'rejected']), average_rating: ratings.length ? round(ratings.reduce((total, rating) => total + rating, 0) / ratings.length) : null, feedback_count: list(data?.feedback).length };
}
function access(data) {
 const roles = list(data?.roles), permissionCodes = new Set(list(data?.permissions).map(row => code(row.code)).filter(Boolean));
 return { role_count: roles.length, active_role_count: roles.filter(row => row.active && !row.archived_at).length, permission_count: permissionCodes.size,
  roles: roles.slice(0, 24).map(row => ({ role: code(row.code), active: bool(row.active), permissions: Array.isArray(row.permissions) ? row.permissions.filter(value => permissionCodes.has(value)).slice(0, 40) : [] })) };
}

export function validatePageAccess(session, page) {
 if (!session?.role || !Object.hasOwn(pages, page)) return false;
 if (page === 'self') return !!session.staff_id;
 if (session.role === 'owner') return true;
 return Object.hasOwn(pagePermissions, page) && has(session, pagePermissions[page]);
}
function forbidden(status = 403) {
 const error = new Error(status === 401 ? 'UNAUTHORIZED' : 'FORBIDDEN'); error.code = error.message; error.status = status; error.statusCode = status; return error;
}
function permissionStatus(error) {
 const status = Number(error?.status ?? error?.statusCode);
 if (status === 401 || error?.code === 'UNAUTHORIZED') return 401;
 if (status === 403 || error?.code === '42501' || error?.code === 'FORBIDDEN' || /FORBIDDEN|permission denied/i.test(error?.message || '')) return 403;
 return null;
}

function validShape(name, value) {
 const object = item => !!item && typeof item === 'object' && !Array.isArray(item);
 const arrays = (item, keys) => object(item) && keys.every(key => Array.isArray(item[key]) && item[key].every(object));
 const numbers = (item, keys) => object(item) && keys.every(key => number(item[key]) !== undefined);
 const rowsHave = (rows, keys) => Array.isArray(rows) && rows.every(row => numbers(row, keys));
 switch (name) {
  case 'spa_catalog': return arrays(value, ['services', 'website_addons', 'business_hours', 'staff']) && numbers(value.settings, ['opening_minute', 'closing_minute', 'booking_days', 'slot_minutes']) && rowsHave(value.services, ['price_cents', 'duration_minutes']);
  case 'spa_dashboard': return numbers(value, ['appointments', 'pending', 'completed', 'cancelled', 'staff_working', 'rooms_active']) && object(value.today_hours);
  case 'spa_operations_convenience': return arrays(value, ['beds', 'todos']) && rowsHave(value.beds, ['overlap_count']) && rowsHave(value.todos, ['count']);
  case 'spa_admin_bookings': return Array.isArray(value) && value.every(row => object(row) && typeof row.staff_id === 'string' && bookingStatuses.includes(row.status));
  case 'spa_customers_list': return rowsHave(value, ['balance_cents', 'visits', 'no_shows', 'total_spend_cents']);
  case 'spa_catalog_admin': return arrays(value, ['services', 'products']) && rowsHave(value.services, ['price_cents', 'duration_minutes']) && rowsHave(value.products, ['price_cents', 'inventory', 'low_stock_threshold']);
  case 'spa_team_os': return arrays(value, ['staff', 'job_titles', 'shifts', 'daily_shifts', 'time_off', 'accounts']);
  case 'spa_payroll_admin': return arrays(value, ['preview', 'rules', 'rates', 'tiers', 'compensation_profiles', 'time_entries', 'overtime', 'runs']) && rowsHave(value.preview, ['total_cents', 'work_minutes', 'service_count']);
  case 'spa_staff_self': return numbers(value.metrics, ['completed', 'settled_completed', 'unsettled_completed', 'minutes', 'work_minutes', 'commission_cents', 'total_cents']) && object(value.profile) && arrays(value, ['shifts', 'daily_shifts', 'time_off']);
  case 'spa_attendance_self': return arrays(value, ['rows', 'requests']) && numbers(value.settings, ['max_shift_minutes', 'grace_minutes', 'radius_m', 'max_accuracy_m']);
  case 'spa_report': return numbers(value, ['bookings', 'completed', 'cancelled', 'no_show', 'revenue_cents', 'cash_in_cents', 'cash_out_cents', 'wallet_liability_cents']) && arrays(value, ['cash_entries', 'staff', 'daily']);
  case 'spa_settings_os': return numbers(value.booking, ['opening_minute', 'closing_minute', 'slot_minutes', 'booking_days']) && arrays(value, ['resources', 'business_hours', 'business_overrides']) && object(value.assignment);
  case 'spa_reviews_admin': return arrays(value, ['reviews', 'feedback']) && rowsHave(value.reviews, ['rating']);
  case 'spa_access_admin': return arrays(value, ['roles', 'permissions']) && value.roles.every(row => typeof row.code === 'string' && Array.isArray(row.permissions));
  default: return false;
 }
}

export async function gatherStewardContext({ session, page, range, rpc, now = new Date() }) {
 if (!validatePageAccess(session, page)) throw forbidden();
 const today = taipeiDate(now), selected = range ?? { from: today, to: today };
 if (!validRange(selected)) { const error = new Error('INVALID_DATE'); error.code = 'INVALID_DATE'; error.status = 400; throw error; }
 if (typeof rpc !== 'function') throw new TypeError('A JWT-bound read RPC function is required.');
 const state = { page, range: { from: selected.from, to: selected.to }, as_of: now.toISOString(), timezone: 'Asia/Taipei', money_unit: 'NTD', percentage_unit: 'percent', time_unit: 'minutes' }, sources = [], failures = [];
 const args = { p_from: selected.from, p_to: selected.to };
 async function read(name, key, sourceLabel, project, parameters = {}) {
  try {
   const data = await rpc(name, parameters);
   // Support an injected raw Supabase RPC client as well as a throwing wrapper.
   if (data?.error) throw data.error;
   const value = data && Object.hasOwn(data, 'data') && Object.hasOwn(data, 'error') ? data.data : data;
   if (!validShape(name, value)) throw new Error('INVALID_RESULT');
   state[key] = project(value);
   sources.push({ label: sourceLabel, section: '即時門店摘要' });
  } catch (error) {
   const status = permissionStatus(error); if (status) throw forbidden(status);
   failures.push({ rpc: name, label: sourceLabel, code: ['INVALID_DATE', 'PAYROLL_RULE_REQUIRED'].includes(error?.code || error?.message) ? error.code || error.message : 'READ_FAILED' });
  }
 }
 await read('spa_catalog', 'public_catalog', '目前公開療程與營業規則', catalog);
 if (has(session, 'dashboard.view')) {
  await read('spa_dashboard', 'dashboard', '今日營運數字', data => dashboard(data, session));
  await read('spa_operations_convenience', 'operations', '即時床位與待辦數量', data => convenience(data, session));
 }
 if (page === 'bookings') await read('spa_admin_bookings', 'bookings', '所選日期預約統計', data => bookings(data, session), args);
 if (page === 'customers' || page === 'pos') await read('spa_customers_list', 'customers', '會員與儲值彙總', customers);
 if (page === 'catalog' || page === 'pos') await read('spa_catalog_admin', 'catalog', '療程商品與庫存', adminCatalog);
 if (page === 'team') await read('spa_team_os', 'team', '人員與排班彙總', team);
 if (page === 'payroll') await read('spa_payroll_admin', 'payroll', '所選日期薪資試算與有效制度', data => payroll(data, selected), { ...args, p_rule: null });
 if (page === 'self') {
  await read('spa_staff_self', 'self', '本人服務績效與薪資', ownSelf, args);
  await read('spa_attendance_self', 'attendance', '本人出勤狀態彙總', ownAttendance, args);
 }
 if (page === 'reports') await read('spa_report', 'reports', '所選日期經營報表彙總', reports, args);
 if (page === 'settings') await read('spa_settings_os', 'settings', '門店預約營業與床位設定', settings);
 if (page === 'reviews') await read('spa_reviews_admin', 'reviews', '評價狀態與評分彙總', reviews);
 if (page === 'access') await read('spa_access_admin', 'access', '角色與權限配置', access);
 // Strip undefined leaves and detach every projected value from its source.
 return { state: JSON.parse(JSON.stringify(state)), sources, failures, pageLabel: pages[page] };
}
