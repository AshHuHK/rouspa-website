export function createPublicRpc({ url, key, fetchImpl = globalThis.fetch, timeoutMs = 25000 }) {
  return async function publicRpc(name, args = {}) {
    const body = JSON.stringify(args), controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
    try {
      const response = await fetchImpl(`${url}/rest/v1/rpc/${encodeURIComponent(name)}`, {
        method: 'POST', credentials: 'omit', signal: controller.signal,
        headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
        body
      });
      const text = await response.text();
      let data = null;
      if (text) { try { data = JSON.parse(text); } catch { data = text; } }
      if (!response.ok) {
        const error = new Error(data?.message || text || `HTTP ${response.status}`);
        if (data && typeof data === 'object') Object.assign(error, data);
        throw error;
      }
      return data;
    } catch (error) {
      if (timedOut) throw new Error('PUBLIC_REQUEST_TIMEOUT');
      if (error instanceof TypeError) throw new Error('PUBLIC_NETWORK_ERROR');
      throw error;
    } finally { clearTimeout(timer); }
  };
}
