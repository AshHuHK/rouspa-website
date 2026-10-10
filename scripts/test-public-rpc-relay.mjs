import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createPublicRpcHandler } from '../server/public-rpc.mjs';
import { PUBLIC_SUPABASE_URL, PUBLIC_SUPABASE_KEY } from '../src/lib/public-config.js';
import { PUBLIC_BOOKING_RELEASE } from '../src/lib/public-rpc.js';

let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const requests = [];
const success = async (url, init) => { requests.push({ url, init }); return new Response(JSON.stringify({ test: true })); };
async function invoke(body = { rpc: 'spa_catalog', args: {} }, options = {}) {
  const headers = { 'content-type': 'application/json', origin: 'https://www.rouspa.tw', ...options.headers };
  const req = { method: options.method || 'POST', headers, body };
  const res = { headers: {}, setHeader(key, value) { this.headers[key.toLowerCase()] = value; }, end(raw) { this.body = JSON.parse(raw); } };
  await createPublicRpcHandler({ fetchImpl: options.fetchImpl || success, env: options.env || { NODE_ENV: 'production' }, timeoutMs: options.timeoutMs || 100 })(req, res);
  return res;
}

const catalog = await invoke();
check(catalog.statusCode === 200 && catalog.body.test, 'anonymous catalog response is passed through');
check(catalog.headers['cache-control'].includes('no-store') && catalog.headers['x-robots-tag'].includes('noindex') && catalog.headers['x-booking-service-version'] === PUBLIC_BOOKING_RELEASE, 'private responses are not cached or indexed and carry the diagnostic release');

const payload = { p_request: 'b0a331d8-44e5-4a9e-a7dc-2e3cc87b1b35', p_name: 'Test only', p_phone: '0000000001' };
await invoke({ rpc: 'spa_create_booking', args: payload }, { headers: { authorization: 'Bearer fake-owner-token', cookie: 'fake-owner-session', apikey: 'fake-private-key' } });
await invoke({ rpc: 'spa_create_booking', args: payload });
check(requests.slice(-2).every(request => request.url === PUBLIC_SUPABASE_URL + '/rest/v1/rpc/spa_create_booking' && JSON.parse(request.init.body).p_request === payload.p_request), 'retry sends the same booking operation ID to the pinned project');
check(requests.every(request => request.init.headers.apikey === PUBLIC_SUPABASE_KEY && request.init.headers.authorization === 'Bearer ' + PUBLIC_SUPABASE_KEY && !request.init.headers.cookie && request.init.credentials === 'omit'), 'relay always uses anonymous public credentials, never caller credentials');
const access = '23ea90a3-0092-4aaa-9517-292196556cec';
await invoke({ rpc: 'spa_member_detail', args: { p_access: access } });
check(JSON.parse(requests.at(-1).init.body).p_access === access, 'customer access proof is preserved for the database to validate');

for (const rpc of ['spa_admin_dashboard', 'spa_payroll_preview', 'spa_staff_schedule_submit', 'spa_settings_save', 'https://private.example/rpc']) {
  const before = requests.length, result = await invoke({ rpc, args: {} });
  check(result.statusCode === 400 && requests.length === before, 'forbidden RPC never reaches upstream: ' + rpc);
}
for (const body of [null, [], { rpc: 'spa_catalog', args: [] }, { rpc: 'spa_catalog' }, { rpc: 'spa_catalog', args: {}, url: 'https://private.example' }]) {
  const before = requests.length, result = await invoke(body);
  check(result.statusCode === 400 && requests.length === before, 'invalid payload is rejected before any upstream call');
}
const beforeInvalid = requests.length;
check((await invoke(undefined, { method: 'GET' })).statusCode === 405, 'GET cannot perform public mutations');
check((await invoke(undefined, { headers: { origin: 'https://unrelated.example' } })).statusCode === 403, 'cross-site browser origins are rejected');
check((await invoke(undefined, { headers: { origin: 'http://localhost:4178' } })).statusCode === 403, 'production does not accept local development origins');
check((await invoke(undefined, { headers: { 'content-type': 'text/plain' } })).statusCode === 415, 'form and plain-text posts cannot bypass JSON validation');
check((await invoke({ rpc: 'spa_submit_feedback', args: { p_message: '中'.repeat(6000) } })).statusCode === 413, 'body size is limited by UTF-8 bytes');
check(requests.length === beforeInvalid, 'rejected input does not consume upstream requests');
check((await invoke(undefined, { headers: { origin: 'http://localhost:4178' }, env: { NODE_ENV: 'development' } })).statusCode === 200, 'local integration testing is explicitly permitted outside production');
check((await invoke(undefined, { headers: { origin: 'https://rouspa-qa.vercel.app' }, env: { NODE_ENV: 'production', VERCEL_URL: 'rouspa-qa.vercel.app' } })).statusCode === 200, 'deployment preview origin can use its own endpoint');
check((await invoke(undefined, { headers: { origin: undefined } })).statusCode === 200, 'anonymous server callers retain existing public access');

const known = await invoke(undefined, { fetchImpl: async () => new Response(JSON.stringify({ message: 'SLOT_TAKEN', details: 'private-customer-value', hint: 'private SQL hint' }), { status: 409 }) });
check(known.statusCode === 409 && known.body.message === 'SLOT_TAKEN' && Object.keys(known.body).length === 1, 'public business errors survive without private upstream details');
const unknown = await invoke(undefined, { fetchImpl: async () => new Response(JSON.stringify({ message: 'duplicate private-customer-value', details: 'SQL detail' }), { status: 500 }) });
check(unknown.statusCode === 503 && unknown.body.message === 'PUBLIC_SERVICE_UNAVAILABLE' && !JSON.stringify(unknown).includes('private-customer'), 'unknown upstream failures expose no private SQL values');
check((await invoke(undefined, { fetchImpl: async () => { throw new TypeError('Network failure'); } })).statusCode === 503, 'network failures terminate with a friendly service error');
check((await invoke(undefined, { fetchImpl: async () => new Response('<html>CDN failure</html>') })).statusCode === 503, 'invalid upstream JSON is not mistaken for a receipt');
const empty = await invoke(undefined, { fetchImpl: async () => new Response(null, { status: 204 }) });
check(empty.statusCode === 200 && empty.body === null, 'empty upstream results use a valid JSON null response');

let signal;
const stalled = await invoke(undefined, { timeoutMs: 15, fetchImpl: (_, init) => { signal = init.signal; return new Promise(() => {}); } });
check(stalled.statusCode === 504 && stalled.body.message === 'PUBLIC_REQUEST_TIMEOUT' && signal.aborted, 'server deadline responds even when upstream ignores abort');
const stalledBody = await invoke(undefined, { timeoutMs: 15, fetchImpl: async () => ({ ok: true, status: 200, text: () => new Promise(() => {}) }) });
check(stalledBody.statusCode === 504 && stalledBody.body.message === 'PUBLIC_REQUEST_TIMEOUT', 'server deadline includes reading the response body');

// Check the actual public call sites so a transport change cannot silently
// break an unrelated customer page such as the shop or review portal.
const used = new Set(['spa_customer_cancel', 'spa_customer_reschedule']);
async function inspect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = new URL(entry.name + (entry.isDirectory() ? '/' : ''), directory);
    if (entry.isDirectory()) await inspect(path);
    else if (/\.(jsx?|mjs)$/.test(entry.name)) {
      const source = await readFile(path, 'utf8');
      for (const match of source.matchAll(/(?:publicRpc|usePublicData)\(\s*['"](spa_[a-z_]+)['"]/g)) used.add(match[1]);
    }
  }
}
await inspect(new URL('../src/', import.meta.url));
for (const rpc of used) check((await invoke({ rpc, args: {} })).statusCode === 200, 'existing public page RPC remains available: ' + rpc);
console.log(`Public RPC relay checks passed: ${checks}; public page RPCs: ${used.size}`);
