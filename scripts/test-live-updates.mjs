import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { createLiveUpdateBus, createRefreshController, isEditingDocument, LIVE_TOPICS } from '../src/lib/live-updates.js';

let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const reject = async (fn, pattern) => { await assert.rejects(fn, pattern); checks++; };
const tick = async () => { for (let n = 0; n < 8; n++) await Promise.resolve(); };

// Real transport lifecycle with a fake Supabase socket, including late async
// authentication, subscriber fanout, catch-up, and disposal.
const win = new EventTarget();
win.navigator = { onLine: true };
const doc = new EventTarget();
doc.visibilityState = 'visible';
let authListener, authCleanup = 0;
const channels = [], removed = [], tokens = [];
let session = { access_token: 'test-session' };
const client = {
  auth: {
    getSession: async () => ({ data: { session } }),
    onAuthStateChange: listener => { authListener = listener; return { data: { subscription: { unsubscribe() { authCleanup++; } } } }; },
  },
  realtime: { setAuth: async token => { tokens.push(token); } },
  channel(topic, options) {
    const channel = { topic, options, on(type, filter, listener) { this.listener = listener; return this; }, subscribe(listener) { this.status = listener; return this; } };
    channels.push(channel);
    return channel;
  },
  removeChannel: async channel => { removed.push(channel); },
};
const bus = createLiveUpdateBus(client, { window: win, document: doc });
const eventsA = [], eventsB = [], publicEvents = [];
const offA = bus.subscribe('operations', event => eventsA.push(event));
const offB = bus.subscribe('operations', event => eventsB.push(event));
await tick();
check(channels.length === 1 && channels[0].options.config.private && tokens[0] === 'test-session', 'operations listeners share one authenticated private channel');
channels[0].status('SUBSCRIBED');
check(eventsA.at(-1).catchup && eventsB.at(-1).catchup && bus.getStatus('operations') === 'connected', 'successful join catches every listener up once');
channels[0].listener({ payload: { scopes: ['appointments', 'appointments', 'customer-secret'], id: 'PII-is-ignored' } });
check(JSON.stringify(eventsA.at(-1)) === JSON.stringify({ type: 'invalidate', scopes: ['appointments'] }) && JSON.stringify(eventsA.at(-1)) === JSON.stringify(eventsB.at(-1)), 'fanout normalizes scopes and discards unknown scopes and payload details');
const offPublic = bus.subscribe('public', event => publicEvents.push(event));
await tick();
check(channels.length === 2 && channels[1].topic === LIVE_TOPICS.public && channels[1].options.config.private === false, 'public channel requires no staff JWT');
channels[1].listener({ payload: { scopes: ['payroll', 'customers', 'catalog', 'availability', 'member'] } });
check(JSON.stringify(publicEvents.at(-1).scopes) === JSON.stringify(['catalog', 'availability', 'member']), 'anonymous hints accept only safe generic public scopes');
offA();
check(removed.length === 0, 'removing one consumer does not tear down another consumer channel');
win.navigator.onLine = false;
win.dispatchEvent(new Event('offline'));
check(bus.getStatus('operations') === 'offline' && removed.length === 2, 'offline tears down both sockets without polling');
const oldEvents = eventsB.length;
channels[0].listener({ payload: { scopes: ['appointments'] } });
check(eventsB.length === oldEvents, 'late messages from obsolete sockets are ignored');
win.navigator.onLine = true;
win.dispatchEvent(new Event('online'));
await tick();
check(channels.length === 4, 'online creates exactly one replacement channel per active audience');
channels.findLast(channel => channel.topic === LIVE_TOPICS.operations).status('SUBSCRIBED');
check(eventsB.at(-1).catchup, 'reconnection performs one catch-up invalidation');
doc.visibilityState = 'hidden';
doc.dispatchEvent(new Event('visibilitychange'));
check(eventsB.at(-1).catchup, 'hidden state does not create a new fetch request');
doc.visibilityState = 'visible';
const previous = eventsB.length;
doc.dispatchEvent(new Event('visibilitychange'));
check(eventsB.length === previous + 1 && eventsB.at(-1).catchup, 'returning to visible catches up once');
const beforeFocus = eventsB.length;
win.dispatchEvent(new Event('focus'));
check(eventsB.length === beforeFocus + 1 && eventsB.at(-1).catchup, 'window refocus catches up even when document visibility never changed');
session = null;
authListener('SIGNED_OUT');
await tick();
check(bus.getStatus('operations') === 'unauthenticated', 'sign-out immediately removes the private transport and updates connection status');
offB(); offPublic();
check(authCleanup === 1, 'final consumers remove shared Auth and browser listeners');
const lateOff = bus.subscribe('operations', () => {});
lateOff();
await tick();
check(bus.getStatus('operations') === 'disconnected', 'unmount during async authentication cannot attach a channel later');

// Deterministic clock: these timers only debounce events, never poll.
const timers = new Map(); let timerId = 0, allowed = true, calls = 0, resolveFetch;
const controller = createRefreshController({
  callback: () => { calls++; return new Promise(resolve => { resolveFetch = resolve; }); },
  canRefresh: () => allowed,
  setTimer: fn => { timers.set(++timerId, fn); return timerId; },
  clearTimer: id => timers.delete(id),
});
async function runTimers() { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } await tick(); }
controller.invalidate(); controller.invalidate(); controller.invalidate();
check(timers.size === 1 && controller.pending, 'a burst schedules one debounced fetch');
await runTimers();
check(calls === 1 && !controller.pending, 'a burst fetches exactly once');
controller.invalidate(); controller.invalidate();
check(timers.size === 0 && controller.pending, 'events received while fetching are retained without parallel fetches');
resolveFetch(); await tick(); await runTimers();
check(calls === 2, 'one follow-up fetch covers the events received during an earlier fetch');
resolveFetch(); await tick();
allowed = false; controller.invalidate(); await runTimers();
check(calls === 2 && controller.pending && timers.size === 0, 'hidden/offline/edit/paused guards keep invalidation queued');
allowed = true; controller.resume(); await runTimers();
check(calls === 3 && !controller.pending, 'resume flushes one pending refresh');
controller.invalidate(); controller.dispose(); resolveFetch(); await tick(); await runTimers();
check(calls === 3 && timers.size === 0, 'disposing a busy consumer never schedules another fetch');
const edited = { activeElement: { matches: () => true }, querySelector: () => null };
check(isEditingDocument(edited), 'focused form field protects unsaved inline edits');
check(isEditingDocument({ activeElement: null, querySelector: () => ({ open: true }) }), 'open dialog protects edits even without a focused input');
check(!isEditingDocument({ activeElement: null, querySelector: () => null }), 'unfocused dashboard can refresh normally');

// Apply actual migrations once without Realtime: local fixtures stay usable.
const db = new PGlite();
await db.exec(`create role anon; create role authenticated; create role service_role;
create schema auth; create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated;
grant execute on function auth.uid(),auth.jwt() to anon,authenticated;`);
const directory = new URL('../supabase/migrations/', import.meta.url);
for (const file of (await readdir(directory)).filter(file => file.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(file, directory), 'utf8'));
await db.exec('update public.spa_settings set id=id');
check((await db.query('select count(*)::int count from spa_private.live_invalidations')).rows[0].count === 0, 'absent Realtime safely skips sends and empties the transaction queue');
const aclsBefore = (await db.query("select relname,relacl::text acl from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' order by relname")).rows;
const accessRpcs = "select proname,proacl::text acl,pg_get_functiondef(p.oid) body from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname in ('spa_member_detail','spa_member_login','spa_customer_booking_list','spa_lookup_bookings') order by proname";
const rpcsBefore = (await db.query(accessRpcs)).rows;

// Installed Supabase runtime substitute captures actual realtime.send calls and
// has RLS enabled already. Grants here model Supabase's installed runtime only.
await db.exec(`create schema realtime;
create table realtime.messages(id bigint generated always as identity,extension text,topic text);
alter table realtime.messages enable row level security;
grant usage on schema realtime to anon,authenticated;
grant select on realtime.messages to anon,authenticated;
create function realtime.topic() returns text language sql stable as $$select current_setting('request.realtime.topic',true)$$;
create table public.live_test_broadcasts(payload jsonb,event text,topic text,is_private boolean);
create function realtime.send(payload jsonb,event text,topic text,is_private boolean) returns void language sql as $$insert into public.live_test_broadcasts values(payload,event,topic,is_private)$$;`);
const migration = await readFile(new URL('202610080009_realtime_updates.sql', directory), 'utf8');
await db.exec(migration);
const aclsAfter = (await db.query("select relname,relacl::text acl from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relname<>'live_test_broadcasts' order by relname")).rows;
check(JSON.stringify(aclsBefore) === JSON.stringify(aclsAfter), 'live transport adds no SELECT grants to business data');
check(JSON.stringify(rpcsBefore) === JSON.stringify((await db.query(accessRpcs)).rows), 'member and booking access-token RPC bodies and execution grants are unchanged');
await db.exec('begin; update spa_settings set id=id; update spa_services set name=name; update spa_services set name=name;');
check((await db.query('select count(*)::int count from live_test_broadcasts')).rows[0].count === 0, 'deferred invalidation sends nothing before commit');
await db.exec('commit');
let broadcasts = (await db.query('select * from live_test_broadcasts order by topic')).rows;
check(broadcasts.length === 2 && broadcasts.every(row => row.event === 'invalidate'), 'many statements in one transaction emit exactly one hint per audience');
const operations = broadcasts.find(row => row.is_private), publicHint = broadcasts.find(row => !row.is_private);
check(operations.topic === LIVE_TOPICS.operations && publicHint.topic === LIVE_TOPICS.public, 'database private/public flags match client channels');
check(operations.payload.scopes.includes('catalog') && operations.payload.scopes.includes('settings') && operations.payload.scopes.length === new Set(operations.payload.scopes).size, 'transaction coalescing retains the union of all affected scopes once');
check(Object.keys(operations.payload).sort().join(',') === 'scopes,timestamp' && Object.keys(publicHint.payload).sort().join(',') === 'scopes,timestamp', 'payload contains only generic scopes and timestamp, without row values or IDs');
check(publicHint.payload.scopes.every(scope => ['catalog', 'hours', 'availability', 'member'].includes(scope)), 'public database broadcast never includes business-only hints');
await db.exec('truncate live_test_broadcasts');
await db.exec('begin; update spa_customers set name=name; rollback;');
check((await db.query('select count(*)::int count from live_test_broadcasts')).rows[0].count === 0, 'rolled-back writes produce no broadcast');
await db.exec('update spa_feedback set status=status where false');
broadcasts = (await db.query('select * from live_test_broadcasts')).rows;
check(broadcasts.length === 1 && broadcasts[0].is_private && broadcasts[0].payload.scopes.includes('reviews'), 'private staff feedback writes send no anonymous hints');
check((await db.query('select count(*)::int count from spa_private.live_invalidations')).rows[0].count === 0, 'committed broadcasts leave no retained queue rows');
for (const [table, column] of [
  ['spa_appointments','status'], ['spa_checkouts','id'], ['spa_orders','status'], ['spa_order_items','id'], ['spa_sale_requests','request_id'],
  ['spa_reviews','rating'], ['spa_coupons','id'], ['spa_customers','name'], ['spa_packages','name'], ['spa_package_entries','id'], ['spa_wallet_entries','id'],
]) {
  await db.exec('truncate live_test_broadcasts');
  await db.exec(`update ${table} set ${column}=${column} where false`);
  const hint = (await db.query("select payload from live_test_broadcasts where topic='rou-spa:public'")).rows[0]?.payload;
  check(hint?.scopes.includes('member') && Object.keys(hint).sort().join(',') === 'scopes,timestamp' && hint.scopes.every(scope => ['catalog','hours','availability','member'].includes(scope)), `${table} sends a generic public member hint with no identifiers, counts or business data`);
}

const coveredTables = (await db.query("select c.relname from pg_trigger t join pg_class c on c.oid=t.tgrelid where t.tgname='spa_live_invalidation'")).rows.map(row => row.relname);
for (const table of ['spa_appointments','spa_checkouts','spa_orders','spa_order_items','spa_reviews','spa_coupons','spa_staff_schedule_submissions','spa_staff_schedule_change_requests','spa_attendance','spa_attendance_requests','spa_payroll_runs','spa_time_entries','spa_payroll_source_snapshots','spa_roles','spa_services','spa_business_hours']) check(coveredTables.includes(table), `database trigger covers ${table}`);
check(!migration.includes('alter publication') && !migration.includes('broadcast_changes'), 'no raw-row replication or payload is enabled');

const owner = randomUUID(), staffUser = randomUUID(), outsider = randomUUID();
const staff = (await db.query("select id from spa_staff where active and employment_status='active' and archived_at is null limit 1")).rows[0].id;
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)', [owner,'owner@live.test',staffUser,'staff@live.test',outsider,'outsider@live.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',null,null),($2,'therapist',$3,'live_staff')", [owner,staffUser,staff]);
await db.exec("insert into realtime.messages(extension,topic) values('broadcast','rou-spa:operations'),('broadcast','another-topic'),('presence','rou-spa:operations')");
async function as(user, sql, { topic = LIVE_TOPICS.operations, iat = Math.floor(Date.now() / 1000) + 60 } = {}) {
  await db.exec('begin');
  try {
    await db.exec('set local role ' + (user ? 'authenticated' : 'anon'));
    await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true),set_config('request.realtime.topic',$3,true)", [user || '', JSON.stringify({ iat }), topic]);
    const result = await db.query(sql);
    await db.exec('commit');
    return result.rows;
  } catch (error) { await db.exec('rollback'); throw error; }
}
check((await as(owner, 'select * from realtime.messages')).length === 1, 'valid owner can receive only broadcast extension on the intended private topic');
check((await as(staffUser, 'select * from realtime.messages')).length === 1, 'valid active staff can receive private hints');
check((await as(outsider, 'select * from realtime.messages')).length === 0, 'unlinked authenticated user cannot receive operations hints');
check((await as(null, 'select * from realtime.messages')).length === 0, 'anonymous user cannot join private operations transport');
check((await as(owner, 'select * from realtime.messages', { topic: 'another-topic' })).length === 0, 'staff receive policy grants no other private topic');
await reject(() => as(staffUser, "insert into realtime.messages(extension,topic) values('broadcast','rou-spa:operations')"), /permission denied/);
await reject(() => as(staffUser, 'select * from spa_private.live_invalidations'), /permission denied/);
await reject(() => as(null, 'select spa_private.can_receive_operations()'), /permission denied/);
await db.query('update spa_roles set login_after=now()+interval \'1 hour\' where user_id=$1', [staffUser]);
check((await as(staffUser, 'select * from realtime.messages')).length === 0, 'password-reset cutoff rejects a previously issued JWT');
await db.query('update spa_roles set login_after=null,active=false where user_id=$1', [staffUser]);
check((await as(staffUser, 'select * from realtime.messages')).length === 0, 'disabled account cannot subscribe');
await db.query('update spa_roles set active=true where user_id=$1', [staffUser]);
await db.query("update spa_staff set archived_at=now() where id=$1", [staff]);
check((await as(staffUser, 'select * from realtime.messages')).length === 0, 'archived staff cannot subscribe');
await db.query('update spa_staff set archived_at=null where id=$1', [staff]);
await db.exec("update spa_role_profiles set active=false where code='therapist'");
check((await as(staffUser, 'select * from realtime.messages')).length === 0, 'disabled role profile cannot subscribe');
await db.close();
console.log(`Live update checks passed: ${checks}`);
