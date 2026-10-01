import assert from 'node:assert/strict';
import {isInactiveBooking,canChangeBooking} from '../src/lib/booking-state.js';
const now=Date.parse('2026-10-02T00:00:00+08:00');
let n=0;
const check=(actual,expected,message)=>{assert.equal(actual,expected,message);n++;};
const future={status:'confirmed',starts_at:'2026-10-03T10:00:00+08:00',ends_at:'2026-10-03T10:45:00+08:00',change_before:'2026-10-02T10:00:00+08:00',can_change:true};
check(isInactiveBooking(future,now),false,'future booking is active');
check(canChangeBooking(future,now),true,'future booking before cutoff may change');
for(const status of ['cancelled','completed','no_show']){check(isInactiveBooking({...future,status},now),true,status+' is inactive even if scheduled in future');check(canChangeBooking({...future,status},now),false,status+' cannot change');}
const ongoing={...future,status:'checked_in',starts_at:'2026-10-01T23:30:00+08:00',ends_at:'2026-10-02T00:15:00+08:00'};
check(isInactiveBooking(ongoing,now),false,'overnight service remains active until end');
check(canChangeBooking(ongoing,now),false,'checked-in appointment cannot change');
check(isInactiveBooking({...ongoing,ends_at:'2026-10-02T00:00:00+08:00'},now),true,'exact end transitions to inactive');
check(isInactiveBooking({...ongoing,status:'pending',ends_at:'2026-10-01T23:59:59+08:00'},now),true,'expired unconfirmed booking is inactive without rewriting status');
check(canChangeBooking({...future,change_before:'2026-10-01T23:59:59+08:00'},now),false,'cutoff closes online change');
check(canChangeBooking({...future,can_change:false},now),false,'server denial remains authoritative');
check(isInactiveBooking({...future,ends_at:'2026-10-01T16:00:00Z'},now),true,'UTC and Taiwan timestamps represent the same instant');
console.log(`PASS: ${n} booking-state assertions (terminal statuses, overnight end, Taiwan/UTC boundary, cutoff).`);
