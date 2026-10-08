import assert from 'node:assert/strict';
import { canRebookBooking, createRebookingIntent, resolveRebookingIntent } from '../src/lib/rebooking.js';

let count = 0;
function check(label, fn) { fn(); count += 1; console.log(`✓ ${label}`); }
const history = {
  status: 'completed', service_id: 'service-head', staff_id: 'staff-actual', requested_staff_id: 'staff-requested',
  starts_at: '2026-09-10T02:00:00Z', ends_at: '2026-09-10T03:30:00Z', business_date: '2026-09-10',
  name: 'Private Customer', phone: '0912345678', manage_token: 'private-manage-token', access_token: 'private-member-token',
  price_cents: 100000, service_name: 'Old treatment name', therapist: 'Old therapist name', note: 'private note',
};
const fresh = {
  services: [{ id: 'service-head', name: 'Current treatment', active: true, status: 'active', online_booking_enabled: true,
    price_cents: 236000, duration_minutes: 90 }],
  staff: [{ id: 'staff-actual', name: 'Current therapist', employment_status: 'active', is_bookable: true }],
  skills: [{ staff_id: 'staff-actual', service_id: 'service-head', enabled: true }],
};

check('completed and cancelled records offer a new booking', () => {
  assert.equal(canRebookBooking(history), true);
  assert.equal(canRebookBooking({ ...history, status: 'cancelled' }), true);
});
check('active and no-show records do not create duplicate-booking shortcuts', () => {
  for (const status of ['pending', 'confirmed', 'checked_in', 'in_service', 'no_show', 'unknown']) {
    assert.equal(canRebookBooking({ ...history, status }), false, status);
    assert.equal(createRebookingIntent({ ...history, status }), null, status);
  }
});
check('missing historical service identifiers require normal service selection', () => {
  for (const row of [null, {}, { status: 'completed' }, { ...history, service_id: '' }]) assert.equal(createRebookingIntent(row), null);
});
check('draft uses the actual prior therapist, not the originally requested therapist', () => {
  assert.deepEqual(createRebookingIntent(history), { serviceId: 'service-head', staffId: 'staff-actual' });
});
check('draft never carries contacts, private access tokens, old times or prices', () => {
  const intent = createRebookingIntent(history), serialized = JSON.stringify(intent);
  assert.deepEqual(Object.keys(intent).sort(), ['serviceId', 'staffId']);
  for (const value of [history.name, history.phone, history.manage_token, history.access_token, history.starts_at, history.business_date, String(history.price_cents), history.note]) {
    assert.equal(serialized.includes(value), false, value);
  }
});
check('current eligible service and actual therapist prefill only the method step', () => {
  assert.deepEqual(resolveRebookingIntent(createRebookingIntent(history), fresh), {
    serviceId: 'service-head', staffId: 'staff-actual', method: 'staff', step: 1, reason: 'ready',
  });
});
check('current catalog remains the sole price and duration source', () => {
  const result = resolveRebookingIntent(createRebookingIntent(history), fresh);
  const selected = fresh.services.find(service => service.id === result.serviceId);
  assert.equal(selected.price_cents, 236000);
  assert.equal(selected.duration_minutes, 90);
  assert.equal('price_cents' in result, false);
  assert.equal('starts_at' in result, false);
  assert.equal('date' in result, false);
  assert.equal('start' in result, false);
});
check('removed service requires fresh selection even when names match', () => {
  const renamed = { ...fresh, services: [{ ...fresh.services[0], id: 'new-id', name: history.service_name }] };
  assert.deepEqual(resolveRebookingIntent(createRebookingIntent(history), renamed), {
    serviceId: '', staffId: '', method: '', step: 0, reason: 'service-unavailable',
  });
});
check('inactive, archived, draft and offline-only services cannot be preselected', () => {
  for (const change of [{ active: false }, { status: 'archived' }, { status: 'draft' }, { online_booking_enabled: false }]) {
    const catalog = { ...fresh, services: [{ ...fresh.services[0], ...change }] };
    assert.equal(resolveRebookingIntent(createRebookingIntent(history), catalog).reason, 'service-unavailable');
  }
});
check('departed, hidden and archived therapists fall back to choosing a method', () => {
  for (const change of [{ active: false }, { employment_status: 'departed' }, { is_bookable: false }, { archived_at: '2026-10-01' }]) {
    const catalog = { ...fresh, staff: [{ ...fresh.staff[0], ...change }] };
    assert.deepEqual(resolveRebookingIntent(createRebookingIntent(history), catalog), {
      serviceId: 'service-head', staffId: '', method: '', step: 1, reason: 'therapist-unavailable',
    });
  }
});
check('lost qualification cannot be carried forward from a past appointment', () => {
  for (const skills of [[], [{ ...fresh.skills[0], enabled: false }], [{ ...fresh.skills[0], service_id: 'different-service' }]]) {
    assert.equal(resolveRebookingIntent(createRebookingIntent(history), { ...fresh, skills }).staffId, '');
  }
});
check('unknown or missing therapist IDs do not fall back to a namesake', () => {
  for (const staff_id of [null, '', 'missing-staff']) {
    const intent = createRebookingIntent({ ...history, staff_id });
    assert.equal(resolveRebookingIntent(intent, fresh).method, '');
  }
});
check('missing catalog never treats historical data as currently bookable', () => {
  assert.equal(resolveRebookingIntent(createRebookingIntent(history), null).step, 0);
  assert.equal(resolveRebookingIntent(createRebookingIntent(history), {}).step, 0);
});
check('history and catalog are not mutated by starting a new booking', () => {
  const old = structuredClone(history), catalog = structuredClone(fresh);
  resolveRebookingIntent(createRebookingIntent(history), fresh);
  assert.deepEqual(history, old);
  assert.deepEqual(fresh, catalog);
});
console.log(`\n${count} rebooking checks passed.`);
