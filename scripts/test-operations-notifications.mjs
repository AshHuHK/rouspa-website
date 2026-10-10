import assert from 'node:assert/strict';
import { activeOperationsTodos, changedOperationsTodos, mergeOperationsToasts, operationsTodoIdentity, operationsTodoTotal } from '../src/lib/operations-notifications.js';
import { createOperationsSnapshotStore } from '../src/lib/operations-snapshot.js';

let checks = 0;
function check(actual, expected, message) { assert.deepEqual(actual, expected, message); checks++; }
const todo = (key, count = 1, revision = key, extra = {}) => ({ key, count, revision, module: 'bookings', title: '預約待確認', severity: 'urgent', ...extra });
const first = [todo('pending', 2), todo('arrivals', 1)];
check(changedOperationsTodos(null, first), [], 'initial snapshot is a silent baseline');
check(activeOperationsTodos({ todos: [...first, todo('empty', 0), todo('payroll', 3, 'payroll', { module: 'payroll' })] }, module => module === 'bookings').map(task => task.key), ['pending', 'arrivals'], 'only positive, accessible tasks are shown');
const screenshotTodos = [todo('pending', 4), todo('checkout', 1), todo('schedule', 1, 'schedule', { module: 'team' })];
check(operationsTodoTotal(screenshotTodos), 6, '4 pending bookings, 1 checkout and 1 roster submission make 6 tasks, not 3 categories');
check(operationsTodoTotal(activeOperationsTodos({ todos: screenshotTodos }, module => module === 'bookings')), 5, 'the badge totals only categories this account can see');
check(operationsTodoTotal(screenshotTodos.slice(1)), 2, 'resolved categories disappear from the total');
check(operationsTodoTotal(), 0, 'no data has no pending tasks');
check(operationsTodoTotal([todo('empty', 0), todo('negative', -1), todo('bad', NaN), todo('infinite', Infinity), todo('fraction', 1.5), todo('numeric', '2')]), 2, 'invalid counts cannot produce a broken badge; numeric counts are accepted');
check(activeOperationsTodos({ todos: [todo('infinite', Infinity), todo('fraction', 1.5), todo('valid', 1)] }).map(task => task.key), ['valid'], 'invalid counts do not create phantom reminder categories');
check(changedOperationsTodos(first, first.map(task => ({ ...task, context: { starts_before: 'later' } }))), [], 'changing server navigation cutoff does not repeat a task');
check(changedOperationsTodos(first, [todo('pending', 2, 'replaced'), todo('arrivals')]).map(task => task.key), ['pending'], 'same-count replacement is detected by opaque task revision');
check(changedOperationsTodos(first, [todo('pending', 3), todo('arrivals')]).map(task => task.key), ['pending'], 'count changes update the reminder');
check(changedOperationsTodos(first, [todo('pending', 2, 'pending', { severity: 'normal' }), todo('arrivals')]).map(task => task.key), ['pending'], 'changed urgency updates the reminder');
check(changedOperationsTodos(first, [todo('arrivals')]), [], 'resolved tasks do not generate a popup');
check(changedOperationsTodos([todo('arrivals')], first).map(task => task.key), ['pending'], 'a resolved task that returns is new again');
check(mergeOperationsToasts([], [], first), [], 'dismissed unchanged reminders stay dismissed');
check(mergeOperationsToasts(first, [], [todo('arrivals')]).map(task => task.key), ['arrivals'], 'resolved reminders leave the toast queue');
const newTasks = ['a', 'b', 'c', 'd'].map(key => todo(key));
check(mergeOperationsToasts(first, newTasks, [...first, ...newTasks]).map(task => task.key), ['a', 'b', 'c'], 'at most three popups are visible');
check(mergeOperationsToasts([todo('a')], [todo('a', 2)], [todo('a', 2)]).length, 1, 'an updated category replaces its older popup');
check(operationsTodoIdentity(todo('pending', 1, 'opaque')).includes('starts_before'), false, 'navigation timestamps are excluded from identity');

const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const tick = () => new Promise(resolve => queueMicrotask(resolve));
const readRequests = [], timers = new Map();
let timerSequence = 0, localClock = 1000, disposed = 0;
const store = createOperationsSnapshotStore({
  read: () => { const request = deferred(); readRequests.push(request); return request.promise; },
  schedule: (callback, delay) => { const id = ++timerSequence; timers.set(id, { callback, delay }); return id; },
  cancel: id => timers.delete(id), clock: () => localClock, onDispose: () => { disposed++; },
});
const unsubscribeBoard = store.subscribe(() => {}), unsubscribeBell = store.subscribe(() => {});
const initial = store.ensure(); store.ensure(); store.refreshToken('initial-board'); store.refreshToken('initial-board');
await tick();
check(readRequests.length, 1, 'board and bell share a single initial request and refresh token');
store.refresh(); store.refresh();
localClock = 1100;
readRequests[0].resolve({ todos: first, server_time: '2026-10-08T00:00:00Z', next_refresh_at: '2026-10-08T00:00:10Z' });
await tick(); await tick();
check(readRequests.length, 2, 'hints during a request queue exactly one catch-up read');
readRequests[1].resolve({ todos: [todo('pending', 3)], server_time: '2026-10-08T00:00:01Z', next_refresh_at: '2026-10-08T00:00:10Z' });
await initial;
check(store.getSnapshot().data.todos[0].count, 3, 'latest queued response wins');
check(store.getSnapshot().busy, false, 'busy ends after the queued request');
check([...timers.values()].map(timer => timer.delay), [9000], 'only the exact next server boundary is scheduled');
const [{ callback: boundary }] = timers.values(); timers.clear(); boundary();
await tick();
check(readRequests.length, 3, 'schedule boundary triggers one fresh snapshot');
readRequests[2].reject(new Error('temporary network error'));
await tick(); await tick();
check(store.getSnapshot().data.todos[0].count, 3, 'temporary failures retain the successful snapshot');
check(store.getSnapshot().error, 'temporary network error', 'temporary errors are exposed');
check(store.getSnapshot().forbidden, false, 'ordinary network failure is not reported as permission loss');
const rejected = store.refresh(); await tick(); readRequests[3].reject(new Error('FORBIDDEN'));
await rejected;
check(store.getSnapshot().data, null, 'revoked permissions clear cached tasks and booking data');
check(store.getSnapshot().forbidden, true, 'FORBIDDEN exposes an explicit permission-loss signal');
const transientAfterDenial = store.refresh(); await tick(); readRequests[4].reject(new Error('temporary network error'));
await transientAfterDenial;
check(store.getSnapshot().forbidden, true, 'permission-loss signal remains until access is successfully revalidated');
check(store.getSnapshot().data, null, 'temporary retry failure cannot restore denied data');
const restored = store.refresh(); await tick(); readRequests[5].resolve({ todos: first }); await restored;
check(store.getSnapshot().forbidden, false, 'successful access revalidation resets the permission-loss signal');
const stale = store.refresh(); await tick(); unsubscribeBoard(); unsubscribeBell(); await tick();
readRequests[6].resolve({ todos: first }); await stale;
check(disposed, 1, 'last subscriber disposes its account snapshot');
check(store.getSnapshot().data, null, 'a response after logout cannot restore cached data');
check(store.getSnapshot().forbidden, false, 'account disposal removes the previous account permission-loss signal');
check(timers.size, 0, 'logout clears the boundary timer');

// A synchronous exception must leave the store retryable, too.
let synchronousCalls = 0;
const synchronous = createOperationsSnapshotStore({ read: () => { synchronousCalls++; throw new Error('sync failure'); } });
const unsubscribeSync = synchronous.subscribe(() => {});
await synchronous.ensure(); await synchronous.refresh();
check(synchronousCalls, 2, 'synchronous failures do not pin the request queue');
unsubscribeSync(); await tick();

let liveConnections = 0, liveDisconnections = 0, deliverHint;
const sharedReads = [];
const shared = createOperationsSnapshotStore({
  read: () => { const request = deferred(); sharedReads.push(request); return request.promise; },
  connect: target => {
    liveConnections++;
    deliverHint = () => target.refresh();
    target.setLiveState({ status: 'connected' });
    return () => { liveDisconnections++; };
  },
});
const detachOne = shared.subscribe(() => {}), detachTwo = shared.subscribe(() => {});
check(liveConnections, 1, 'two consumers have exactly one store-owned Realtime subscription');
check(shared.getSnapshot().status, 'connected', 'connection status is shared with both consumers');
const hintRead = deliverHint(); await tick();
check(sharedReads.length, 1, 'one broadcast invokes one RPC despite two consumers');
deliverHint();
sharedReads[0].resolve({ todos: first }); await tick(); await tick();
check(sharedReads.length, 2, 'a genuinely later broadcast in-flight is retained');
sharedReads[1].resolve({ todos: [todo('pending', 3)] }); await hintRead;
detachOne(); await tick();
check(liveDisconnections, 0, 'the board can unmount without stopping the bell subscription');
detachTwo(); await tick();
check(liveDisconnections, 1, 'last consumer releases the shared Realtime subscription');

let prematureReads = 0;
const premature = createOperationsSnapshotStore({ read: () => { prematureReads++; return { todos: first }; } });
premature.subscribe(() => {});
const cancelled = premature.refresh(); premature.dispose(); await cancelled;
check(prematureReads, 0, 'disposing before the request starts prevents the read');
console.log(`Operations notification checks passed: ${checks}`);
