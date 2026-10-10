import { PUBLIC_SUPABASE_URL, PUBLIC_SUPABASE_KEY } from '../src/lib/public-config.js';
import { PUBLIC_BOOKING_RELEASE } from '../src/lib/public-rpc.js';

const PUBLIC_RPCS = new Set([
  'spa_catalog', 'spa_store_catalog', 'spa_server_time', 'spa_public_reviews', 'spa_booking_calendar',
  'spa_public_slots', 'spa_public_available_staff', 'spa_create_booking',
  'spa_review_context', 'spa_submit_review', 'spa_submit_feedback',
  'spa_member_login', 'spa_member_detail', 'spa_customer_booking_list',
  'spa_customer_cancel', 'spa_customer_reschedule', 'spa_customer_availability',
  'spa_customer_review', 'spa_lookup_bookings', 'spa_booking_link_access', 'spa_availability'
]);
const SAFE_ERRORS = new Set([
  'INVALID_SERVICE', 'INVALID_INPUT', 'INVALID_DATE', 'SLOT_TAKEN', 'RATE_LIMIT',
  'CUSTOMER_NAME_MISMATCH', 'CUSTOMER_UNAVAILABLE', 'REQUEST_CONFLICT',
  'BOOKING_ACCESS_EXPIRED', 'FORBIDDEN', 'NOT_FOUND', 'REASON_REQUIRED',
  'RESCHEDULE_CUTOFF', 'CANCELLATION_CUTOFF', 'INVALID_TRANSITION', 'REVIEW_NOT_ELIGIBLE'
]);
const ORIGINS = new Set(['https://www.rouspa.tw', 'https://rouspa.tw']);
const MAX_BODY = 16 * 1024;
class PublicRpcError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
async function readBody(req) {
  if (Number(req.headers?.['content-length']) > MAX_BODY) throw new PublicRpcError(413, 'INVALID_INPUT');
  let raw = '', bytes = 0;
  if (req.body !== undefined) raw = typeof req.body === 'string' || Buffer.isBuffer(req.body) ? String(req.body) : JSON.stringify(req.body);
  else {
    const chunks = [];
    for await (const chunk of req) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += buffer.length;
      if (bytes > MAX_BODY) throw new PublicRpcError(413, 'INVALID_INPUT');
      chunks.push(buffer);
    }
    // Decode after joining so a network chunk cannot split a Chinese character.
    raw = Buffer.concat(chunks).toString('utf8');
  }
  if (Buffer.byteLength(raw) > MAX_BODY) throw new PublicRpcError(413, 'INVALID_INPUT');
  try { return JSON.parse(raw); } catch { throw new PublicRpcError(400, 'INVALID_INPUT'); }
}

export function createPublicRpcHandler({ fetchImpl = globalThis.fetch, env = process.env, timeoutMs = 18000 } = {}) {
  return async function handle(req, res) {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store, private');
    res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive');
    res.setHeader('X-Booking-Service-Version', PUBLIC_BOOKING_RELEASE);
    const reply = (status, body) => { res.statusCode = status; res.end(JSON.stringify(body)); };
    let timer;
    try {
      if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); throw new PublicRpcError(405, 'INVALID_INPUT'); }
      const origin = req.headers?.origin;
      const development = env.NODE_ENV !== 'production' && /^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin || '');
      const preview = env.VERCEL_URL && origin === `https://${env.VERCEL_URL}`;
      if (origin && !ORIGINS.has(origin) && !development && !preview) throw new PublicRpcError(403, 'FORBIDDEN');
      if (!String(req.headers?.['content-type'] || '').toLowerCase().startsWith('application/json')) throw new PublicRpcError(415, 'INVALID_INPUT');
      const body = await readBody(req);
      if (!body || typeof body !== 'object' || Array.isArray(body) || !PUBLIC_RPCS.has(body.rpc)
        || !body.args || typeof body.args !== 'object' || Array.isArray(body.args)
        || Object.keys(body).some(key => !['rpc', 'args'].includes(key))) throw new PublicRpcError(400, 'INVALID_INPUT');
      const controller = new AbortController();
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => { reject(new PublicRpcError(504, 'PUBLIC_REQUEST_TIMEOUT')); controller.abort(); }, timeoutMs);
      });
      const operation = (async () => {
        // Never accept a caller's token, service-role key, URL or arbitrary RPC.
        // Existing anon execution grants and each RPC's checks remain in force.
        const response = await fetchImpl(`${PUBLIC_SUPABASE_URL}/rest/v1/rpc/${body.rpc}`, {
          method: 'POST', credentials: 'omit', signal: controller.signal,
          headers: { apikey: PUBLIC_SUPABASE_KEY, authorization: `Bearer ${PUBLIC_SUPABASE_KEY}`, 'content-type': 'application/json' },
          body: JSON.stringify(body.args)
        });
        const raw = await response.text();
        let data;
        try { data = raw ? JSON.parse(raw) : null; } catch { throw new PublicRpcError(503, 'PUBLIC_SERVICE_UNAVAILABLE'); }
        if (!response.ok) {
          // SQL details can contain private values. Expose only known public
          // business errors, never upstream details, hints or stack traces.
          const message = typeof data?.message === 'string' ? data.message.trim() : '';
          if (SAFE_ERRORS.has(message)) return { status: response.status, data: { message } };
          throw new PublicRpcError(503, 'PUBLIC_SERVICE_UNAVAILABLE');
        }
        return { status: response.status === 204 ? 200 : response.status, data };
      })();
      const result = await Promise.race([operation, deadline]);
      reply(result.status, result.data);
    } catch (error) {
      reply(error instanceof PublicRpcError ? error.status : 503, { message: error instanceof PublicRpcError ? error.message : 'PUBLIC_SERVICE_UNAVAILABLE' });
    } finally { clearTimeout(timer); }
  };
}
