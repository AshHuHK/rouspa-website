import assert from 'node:assert/strict';
import { PUBLIC_SUPABASE_URL } from '../src/lib/public-config.js';

// Read-only deployment smoke check: OPTIONS never looks up an employee, uses a
// password or creates a login attempt. Do not replace with real credentials.
const versions = {'staff-login':'20261025-01','staff-accounts':'20261026-01'};
for (const name of ['staff-login', 'staff-accounts']) {
  for (const origin of ['https://www.rouspa.tw', 'https://rouspa.tw', 'capacitor://localhost', 'https://untrusted.example']) {
    const response = await fetch(`${PUBLIC_SUPABASE_URL}/functions/v1/${name}`, {
      method: 'OPTIONS',
      headers: { origin, 'access-control-request-method': 'POST', 'access-control-request-headers': 'apikey,authorization,content-type,x-client-info' },
      signal: AbortSignal.timeout(15000)
    });
    const trusted = origin !== 'https://untrusted.example';
    assert.equal(response.status, trusted ? 204 : 403, `${name}: unexpected preflight status for ${origin}`);
    assert.equal(response.headers.get('access-control-allow-origin'), trusted ? origin : null, `${name}: incorrect origin policy`);
    assert.equal(response.headers.get('x-staff-service-version'), versions[name], `${name}: deployed function differs from reviewed release`);
    if (trusted) {
      const allowed = response.headers.get('access-control-allow-headers')?.toLowerCase().split(',').map(value => value.trim()) || [];
      for (const header of ['apikey', 'authorization', 'content-type', 'x-client-info']) assert(allowed.includes(header), `${name}: missing header ${header}`);
      assert(response.headers.get('access-control-allow-methods')?.split(',').map(value => value.trim()).includes('POST'), `${name}: POST missing`);
    }
    assert(response.headers.get('cache-control')?.includes('no-store'), `${name}: credentials must never be cached`);
    console.log(`PASS: ${name} ${origin} ${response.status} version ${versions[name]}`);
  }
}
