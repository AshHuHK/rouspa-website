import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createRequestId } from '../src/lib/request-id.js';
import { createPublicRpc } from '../src/lib/public-rpc.js';

let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const rejects = async (action, message) => { await assert.rejects(action, message); checks++; };
const native = { randomUUID() { assert.equal(this, native); return 'native-id'; } };
check(createRequestId(native) === 'native-id', 'native UUID keeps its crypto receiver');
const olderBrowser = { getRandomValues: bytes => webcrypto.getRandomValues(bytes) };
const identifiers = Array.from({ length: 100 }, () => createRequestId(olderBrowser));
check(identifiers.every(value => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value)), 'older browser fallback generates PostgreSQL-compatible UUID v4 values');
check(new Set(identifiers).size === identifiers.length, 'different requests receive independent secure identifiers');
assert.throws(() => createRequestId({}), /BROWSER_RANDOM_UNAVAILABLE/); checks++;

const requests = [];
const options = { url: 'https://public.example.test', key: 'test-publishable-key' };
const rpc = createPublicRpc({ ...options, fetchImpl: async (url, init) => {
  requests.push({ url, init }); return new Response(JSON.stringify({ reference: 'TEST-ONLY' }), { status: 200 });
} });
const payload = { p_request: identifiers[0], p_name: 'Test only' };
check((await rpc('spa_create_booking', payload)).reference === 'TEST-ONLY', 'successful anonymous response reaches the receipt');
await rpc('spa_create_booking', payload);
check(requests[0].url === options.url + '/rest/v1/rpc/spa_create_booking', 'booking targets the configured public project');
check(requests[0].init.credentials === 'omit' && requests[0].init.headers.authorization === 'Bearer ' + options.key, 'public requests never inherit owner cookies or authentication');
check(requests.every(request => JSON.parse(request.init.body).p_request === identifiers[0]), 'retry transmits the same idempotency key unchanged');
check(requests.every(request => !request.init.signal.aborted), 'successful responses cancel their timeout');

const failing = createPublicRpc({ ...options, fetchImpl: async () => new Response(JSON.stringify({ code: '23P01', message: 'SLOT_TAKEN' }), { status: 409 }) });
await rejects(() => failing('spa_create_booking'), { message: 'SLOT_TAKEN', code: '23P01' });
const offline = createPublicRpc({ ...options, fetchImpl: async () => { throw new TypeError('Failed to fetch'); } });
await rejects(() => offline('spa_create_booking'), /PUBLIC_NETWORK_ERROR/);
let aborted = false;
const stalled = createPublicRpc({ ...options, timeoutMs: 15, fetchImpl: async (_, { signal }) => new Promise((resolve, reject) => {
  signal.addEventListener('abort', () => { aborted = true; reject(new DOMException('Aborted', 'AbortError')); }, { once: true });
}) });
await rejects(() => stalled('spa_create_booking'), /PUBLIC_REQUEST_TIMEOUT/);
check(aborted, 'a stalled fetch ends instead of keeping the submit button busy forever');
const stalledBody = createPublicRpc({ ...options, timeoutMs: 15, fetchImpl: async (_, { signal }) => ({
  ok: true, text: () => new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true }))
}) });
await rejects(() => stalledBody('spa_create_booking'), /PUBLIC_REQUEST_TIMEOUT/);
const empty = createPublicRpc({ ...options, fetchImpl: async () => new Response(null, { status: 204 }) });
check(await empty('spa_cancel_booking') === null, 'empty cancellation response remains valid');

const ignoredAbort = createPublicRpc({ ...options, timeoutMs: 15, fetchImpl: () => new Promise(() => {}) });
await rejects(() => ignoredAbort('spa_create_booking'), /PUBLIC_REQUEST_TIMEOUT/);
const ignoredBodyAbort = createPublicRpc({ ...options, timeoutMs: 15, fetchImpl: async () => ({ ok: true, text: () => new Promise(() => {}) }) });
await rejects(() => ignoredBodyAbort('spa_create_booking'), /PUBLIC_REQUEST_TIMEOUT/);
let resolveLate;
const late = createPublicRpc({ ...options, timeoutMs: 15, fetchImpl: () => new Promise(resolve => { resolveLate = resolve; }) });
await rejects(() => late('spa_create_booking'), /PUBLIC_REQUEST_TIMEOUT/);
resolveLate(new Response(JSON.stringify({ reference: 'LATE-TEST-ONLY' })));

const proxyRequests = [];
const proxy = createPublicRpc({ ...options, proxyUrl: '/api/public-rpc', fetchImpl: async (url, init) => {
  proxyRequests.push({ url, init }); return new Response(JSON.stringify({ reference: 'PROXY-TEST-ONLY' }));
} });
check((await proxy('spa_create_booking', payload)).reference === 'PROXY-TEST-ONLY', 'same-origin response reaches the existing receipt');
await proxy('spa_create_booking', payload);
check(proxyRequests.every(request => request.url === '/api/public-rpc'), 'public browser calls use the same-origin endpoint');
check(proxyRequests.every(request => request.init.credentials === 'omit' && Object.keys(request.init.headers).join(',') === 'content-type'), 'same-origin calls never send owner credentials or project API keys');
check(proxyRequests.every(request => JSON.parse(request.init.body).args.p_request === identifiers[0] && JSON.parse(request.init.body).rpc === 'spa_create_booking'), 'same-origin retries preserve the original RPC and operation ID');

const booking = await readFile(new URL('../src/PublicBookingExperience.jsx', import.meta.url), 'utf8');
const submit = booking.slice(booking.indexOf(' async function submit()'), booking.indexOf(' if(rebookingIntent||rebookingBusy)'));
check(submit.indexOf('try{') < submit.indexOf('createRequestId()') && submit.includes('finally{setSubmitting(false);}'), 'identifier creation errors are caught and always restore the booking button');
check(submit.includes('request.current?.fingerprint!==fingerprint') && !submit.includes('request.current=null'), 'ambiguous network failures retain the request ID for safe retries');
console.log(`Public booking client checks passed: ${checks}`);
