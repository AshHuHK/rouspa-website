import assert from 'node:assert/strict';
import { bookingDayClock, bookingDayHours, bookingDayLabel } from '../src/lib/public-booking-presentation.js';

const overnight = { status: 'open', start_minute: 600, end_minute: 1560, available_staff: 2 };
assert.equal(bookingDayHours(overnight), '10:00–翌日 02:00');
assert.equal(bookingDayHours(overnight, 'en'), '10:00–Next day 02:00');
assert.equal(bookingDayClock(1560), '翌02:00');
assert.equal(bookingDayClock(1560, 'en'), '↳02:00');
assert.equal(bookingDayClock(600), '10:00');
assert.equal(bookingDayClock(null), '');
assert.equal(bookingDayHours({ start_minute: 600 }), '');
assert.match(bookingDayLabel('2026-12-01', overnight, { method: 'staff' }), /2026-12-01.*10:00–翌日 02:00/);
assert.match(bookingDayLabel('2027-01-01', overnight, { method: 'staff', lang: 'en' }), /2027-01-01.*Next day 02:00/);
assert.match(bookingDayLabel('2026-12-01', overnight), /2 位可約/);
assert.equal(bookingDayLabel('2026-12-01', { ...overnight, status: 'full' }, { method: 'staff' }), '2026-12-01 · 已滿');
assert.equal(bookingDayLabel('2026-12-01', { status: 'past' }), '2026-12-01 · 已過日期');
assert.equal(bookingDayLabel('2026-12-01', null), '2026-12-01 · 休班／不可預約');
console.log('Public booking presentation checks passed: 13');
