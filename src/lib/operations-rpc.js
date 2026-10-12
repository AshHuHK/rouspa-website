import { unwrapRpcResult } from './rpc-result.js';

export async function readSessionWithDeadline(auth, timeoutMs = 25000) {
  let timer;
  try {
    const response = await Promise.race([
      auth.getSession(),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('OPERATIONS_REQUEST_TIMEOUT')), timeoutMs); }),
    ]);
    if (response.error) throw response.error;
    return response.data?.session || null;
  } finally { clearTimeout(timer); }
}

// A deadline settles the UI even when the network ignores AbortSignal. A
// timed-out mutation may already have committed; its request ID stays intact.
export function createOperationsRpc(client, { timeoutMs = 25000 } = {}) {
  return async (name, args = {}) => {
    const controller = new AbortController();
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => { reject(new Error('OPERATIONS_REQUEST_TIMEOUT')); controller.abort(); }, timeoutMs);
    });
    try {
      const operation = (async () => {
        const query = client.rpc(name, args);
        const { data, error } = await (query.abortSignal ? query.abortSignal(controller.signal) : query);
        if (error) throw error;
        return unwrapRpcResult(data);
      })();
      return await Promise.race([operation, deadline]);
    } catch (error) {
      if (error instanceof TypeError) throw new Error('OPERATIONS_NETWORK_ERROR');
      throw error;
    } finally { clearTimeout(timer); }
  };
}
