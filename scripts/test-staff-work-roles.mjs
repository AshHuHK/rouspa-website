import assert from 'node:assert/strict';
import { allowedEmploymentTypes, isCurrentStaff, isTechnician, posEligibleStaff } from '../src/lib/staff-work-roles.js';

let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const ids = rows => rows.map(row => row.id).sort();
const staff = [
  { id: 'owner', work_category: 'owner', active: true, employment_status: 'active' },
  { id: 'counter', work_category: 'counter', active: true, employment_status: 'active' },
  { id: 'full-time', work_category: 'technician', employment_type_code: 'full_time', active: true, employment_status: 'active' },
  { id: 'part-time', work_category: 'technician', employment_type_code: 'part_time', active: true, employment_status: 'active' },
  { id: 'contractor', work_category: 'technician', employment_type_code: 'contractor', active: true, employment_status: 'active' },
  { id: 'legacy-tech', work_category: 'legacy', job_title_code: 'senior_therapist', legacy: true, active: true, employment_status: 'active' },
  { id: 'legacy-counter', work_category: 'legacy', job_title_code: 'counter', legacy: true, active: true, employment_status: 'active' },
  { id: 'departed', work_category: 'technician', active: true, employment_status: 'departed' },
  { id: 'inactive', work_category: 'technician', active: false, employment_status: 'active' },
  { id: 'inactive-status', work_category: 'technician', active: true, employment_status: 'inactive' },
  { id: 'archived', work_category: 'technician', active: true, employment_status: 'active', archived_at: '2026-10-10T00:00:00Z' },
];
const catalog = {
  staff,
  // A residual owner/counter skill cannot confer a technician classification.
  skills: staff.map(person => ({ staff_id: person.id, service_id: 'head-spa', enabled: true })),
};
const original = structuredClone(catalog);
const product = { id: 'oil', item_type: 'product' }, service = { id: 'head-spa', item_type: 'service' };

for (const id of ['owner', 'counter', 'legacy-counter']) {
  check(!isTechnician(staff.find(row => row.id === id)), `${id} does not gain service eligibility from a residual service skill`);
}
for (const id of ['full-time', 'part-time', 'contractor', 'legacy-tech']) {
  check(isTechnician(staff.find(row => row.id === id)), `${id} retains its actual technician classification`);
}
for (const code of ['therapist', 'senior_therapist', 'head_therapist', 'part_time']) {
  check(isTechnician({ legacy: true, job_title_code: code }), `retained ${code} assignment remains a technician until explicit classification`);
}
check(!isTechnician({ legacy: true, job_title_code: 'unknown' }), 'an unknown legacy title never invents technician eligibility');
check(!isTechnician({ legacy: false, job_title_code: 'therapist' }), 'legacy code alone cannot override an explicitly nonlegacy classification');
assert.deepEqual(ids(posEligibleStaff(service, catalog)), ['contractor', 'full-time', 'legacy-tech', 'part-time']); checks++;
assert.deepEqual(ids(posEligibleStaff(product, catalog)), ['contractor', 'counter', 'full-time', 'legacy-counter', 'legacy-tech', 'owner', 'part-time']); checks++;
for (const id of ['departed', 'inactive', 'inactive-status', 'archived']) {
  check(!isCurrentStaff(staff.find(row => row.id === id)), `${id} is unavailable for every new POS attribution`);
}
check(posEligibleStaff(product, { ...catalog, skills: [] }).length === 7, 'all current staff may sell goods without service skills');
check(posEligibleStaff(service, { ...catalog, skills: [] }).length === 0, 'technician title alone does not grant unconfigured service skills');
const changed = structuredClone(catalog);
changed.skills.find(row => row.staff_id === 'full-time').enabled = false;
check(!posEligibleStaff(service, changed).some(row => row.id === 'full-time'), 'disabling a skill immediately removes that service attribution');
check(posEligibleStaff(product, changed).some(row => row.id === 'full-time'), 'disabling a service skill keeps independent goods attribution available');
check(posEligibleStaff({ ...service, id: 'other-service' }, catalog).length === 0, 'a skill for one service cannot authorize a different service');
check(posEligibleStaff(service, {}).length === 0, 'a missing staff catalog supplies no invented eligible employees');

const fullTime = { id: 'rank-1', legacy: false, allowed_employment_types: ['full_time'] };
const counter = { id: 'counter-title', legacy: false, allowed_employment_types: ['full_time', 'part_time'] };
const owner = { id: 'owner-title', legacy: false, allowed_employment_types: ['owner'] };
const legacy = { id: 'old-title', legacy: true, allowed_employment_types: [] };
assert.deepEqual(allowedEmploymentTypes(fullTime), ['full_time']); checks++;
assert.deepEqual(allowedEmploymentTypes(counter), ['full_time', 'part_time']); checks++;
assert.deepEqual(allowedEmploymentTypes(owner), ['owner']); checks++;
assert.deepEqual(allowedEmploymentTypes(legacy, { job_title_id: 'old-title', employment_type_code: 'full_time' }), ['full_time']); checks++;
assert.deepEqual(allowedEmploymentTypes(legacy, { job_title_id: 'rank-1', employment_type_code: 'full_time' }), []); checks++;
assert.deepEqual(allowedEmploymentTypes(legacy), []); checks++;
assert.deepEqual(allowedEmploymentTypes(fullTime, { job_title_id: 'old-title', employment_type_code: 'part_time' }), ['full_time']); checks++;
assert.deepEqual(allowedEmploymentTypes(undefined), []); checks++;
assert.deepEqual(catalog, original, 'eligibility checks preserve the server catalog and historical identities'); checks++;

console.log(`PASS: ${checks} staff classification, employment and POS attribution assertions`);
