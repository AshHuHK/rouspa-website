export const PUBLIC_BOOKING_RELEASE = '20261010-02';

export function createPublicRpc({ url, key, proxyUrl = null, fetchImpl = globalThis.fetch, timeoutMs = 25000 }) {
  return async function publicRpc(name, args = {}) {
    const body = JSON.stringify(proxyUrl ? { rpc: name, args } : args), controller = new AbortController();
    let timer;
    // Aborting alone is insufficient when a browser/network wrapper ignores the
    // signal. The separate deadline also settles the caller and restores its UI.
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => { reject(new Error('PUBLIC_REQUEST_TIMEOUT')); controller.abort(); }, timeoutMs);
    });
    try {
      const operation = (async () => {
        const response = await fetchImpl(proxyUrl || `${url}/rest/v1/rpc/${encodeURIComponent(name)}`, {
          method: 'POST', credentials: 'omit', signal: controller.signal,
          headers: proxyUrl ? { 'content-type': 'application/json' } : { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
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
      })();
      return await Promise.race([operation, deadline]);
    } catch (error) {
      if (error instanceof TypeError) throw new Error('PUBLIC_NETWORK_ERROR');
      throw error;
    } finally { clearTimeout(timer); }
  };
}
