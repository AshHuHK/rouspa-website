import assert from 'node:assert/strict';
import { preserveSelectedCoupon, reconcilePosCart, weeklyRosterFields, reconcileWeeklyRoster } from '../src/lib/operations-drafts.js';

let checks = 0;
const check = (actual, expected, message) => { assert.deepEqual(actual, expected, message);checks++; };
const coupons = [{ id: 'saved', status: 'active', amount_cents: 5000 }, { id: 'other', status: 'active', amount_cents: 10000 }];
check(preserveSelectedCoupon('saved', structuredClone(coupons)), 'saved', 'unchanged member coupon remains selected after a fresh catalogue read');
check(preserveSelectedCoupon('saved', coupons.filter(coupon => coupon.id !== 'saved')), '', 'redeemed or removed coupon cannot remain selected');
check(preserveSelectedCoupon('saved', [{ ...coupons[0], status: 'redeemed' }]), '', 'a non-active coupon cannot remain applied');
check(preserveSelectedCoupon('', coupons), '', 'refresh never automatically applies a different coupon');

const cart = [{ id: 'product', item_type: 'product', price_cents: 9000, inventory: 3, quantity: 2, staff_id: 'salesperson' }, { id: 'service', item_type: 'service', price_cents: 120000, quantity: 1, staff_id: 'therapist' }];
const original = structuredClone(cart);
const current = { products: [{ id: 'product', price_cents: 10000, inventory: 2 }], services: [{ id: 'service', price_cents: 135000 }] };
const reconciled = reconcilePosCart(cart, current);
check(reconciled.map(row => [row.price_cents, row.quantity, row.staff_id]), [[10000, 2, 'salesperson'], [135000, 1, 'therapist']], 'fresh prices preserve quantities and assigned staff');
check(cart, original, 'fresh catalogue reconciliation never mutates the captured checkout draft');
check(reconcilePosCart(cart, { products: [], services: [] }), cart, 'unavailable catalogue items remain in the draft for explicit operator handling');

const old = weeklyRosterFields({ start_minute: 600, end_minute: 1080 });
const draft = { working: true, start: 660, end: 1200 };
const updated = weeklyRosterFields({ start_minute: 720, end_minute: 1260 });
check(reconcileWeeklyRoster(old, draft, updated, { dirty: true }), { draft, dirty: true, officialChanged: true }, 'concurrent official roster change preserves unsaved weekly hours and flags the change');
check(reconcileWeeklyRoster(old, draft, structuredClone(old), { dirty: true }), { draft, dirty: true, officialChanged: false }, 'an unrelated live event leaves the weekly draft intact');
check(reconcileWeeklyRoster(old, old, updated), { draft: updated, dirty: false, officialChanged: false }, 'unedited weekly hours update immediately');
check(reconcileWeeklyRoster(old, draft, updated, { dirty: true, reset: true }), { draft: updated, dirty: false, officialChanged: false }, 'changing staff or weekday resets to that official roster');
check(reconcileWeeklyRoster(old, draft, draft, { dirty: true }), { draft, dirty: false, officialChanged: true }, 'matching saved official hours clears the dirty marker');
check(weeklyRosterFields(null), { working: false, start: 600, end: 1080 }, 'a missing weekly shift has the standard off-day editor defaults');
check(reconcileWeeklyRoster(old, { working: false, start: 600, end: 1080 }, updated, { dirty: true }).draft.working, false, 'unsaved fixed rest-day choice survives an official update');
console.log(`Operations draft checks passed: ${checks}`);
