// Serialize catalog reads and keep the previous published result visible during
// background updates. Disposal prevents late results from updating a new page.
export function createPublicDataController({ read, onResult, onError, onLoading }) {
  let disposed = false, pending = false, running = null;
  async function drain() {
    onLoading(true);
    try {
      while (pending && !disposed) {
        pending = false;
        try {
          const result = await read();
          if (!disposed) onResult(result);
        } catch (error) { if (!disposed) onError(error); }
      }
    } finally {
      running = null;
      if (!disposed) onLoading(false);
    }
  }
  return {
    refresh() {
      if (disposed) return Promise.resolve(null);
      pending = true;
      if (!running) running = Promise.resolve().then(drain);
      return running;
    },
    dispose() { disposed = true; pending = false; },
  };
}

export function publicAnchorKey(hash, rebookingId) {
  return `${hash}|${rebookingId ?? ''}`;
}
