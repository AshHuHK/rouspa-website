export const EMPTY_OPERATIONS_SNAPSHOT = Object.freeze({ data: null, busy: false, error: '', forbidden: false, status: 'disconnected', pending: false });

// One shared, read-only request queue per signed-in account. Hints received
// during a request trigger another read, so a concurrent change is never lost.
export function createOperationsSnapshotStore({ read, formatError = error => error?.message || String(error), schedule = setTimeout, cancel = clearTimeout, clock = Date.now, canRefresh = () => true, connect, onDispose = () => {} }) {
  const listeners = new Set();
  let snapshot = EMPTY_OPERATIONS_SNAPSHOT, running = null, queued = false, disposed = false;
  let boundaryTimer = null, generation = 0, lastToken;
  let liveStarted = false, disconnectLive;

  const publish = next => { snapshot = next; listeners.forEach(listener => listener()); };
  const clearBoundary = () => { if (boundaryTimer !== null) cancel(boundaryTimer); boundaryTimer = null; };

  function scheduleBoundary(data, startedAt) {
    clearBoundary();
    const boundary = Date.parse(data?.next_refresh_at), server = Date.parse(data?.server_time);
    if (!Number.isFinite(boundary) || !Number.isFinite(server) || boundary <= server || !listeners.size || disposed) return;
    // The server supplies the next actual schedule/date boundary. This is a
    // single timeout, not a recurring refresh interval or an estimated clock.
    const delay = Math.max(1, boundary - server - Math.max(0, clock() - startedAt));
    if (delay > 2147483647) return;
    boundaryTimer = schedule(() => {
      boundaryTimer = null;
      if (canRefresh()) refresh();
    }, delay);
  }

  async function readQueued(requestGeneration) {
    if (disposed || requestGeneration !== generation || !listeners.size) { running = null; return null; }
    let result = null;
    do {
      queued = false;
      clearBoundary();
      publish({ ...snapshot, busy: true });
      const startedAt = clock();
      try {
        result = await read();
        if (disposed || requestGeneration !== generation) return null;
        publish({ ...snapshot, data: result, busy: true, error: '', forbidden: false });
        if (!queued) scheduleBoundary(result, startedAt);
      } catch (error) {
        if (disposed || requestGeneration !== generation) return null;
        const forbidden = !!error?.message?.includes('FORBIDDEN');
        publish({ ...snapshot, data: forbidden ? null : snapshot.data, busy: true, error: formatError(error), forbidden: forbidden || snapshot.forbidden });
        if (forbidden) queued = false;
      }
    } while (queued && listeners.size && !disposed);
    if (!disposed && requestGeneration === generation) {
      running = null;
      publish({ ...snapshot, busy: false });
    }
    return result;
  }

  function refresh() {
    if (disposed || !listeners.size) return Promise.resolve(null);
    if (running) { queued = true; return running; }
    const requestGeneration = generation;
    running = Promise.resolve().then(() => readQueued(requestGeneration));
    return running;
  }

  function dispose() {
    if (disposed) return;
    disposed = true; generation++; queued = false;
    disconnectLive?.();
    clearBoundary(); snapshot = EMPTY_OPERATIONS_SNAPSHOT;
    onDispose();
  }

  const api = {
    getSnapshot: () => snapshot,
    subscribe(listener) {
      listeners.add(listener);
      if (!liveStarted && connect) { liveStarted = true; disconnectLive = connect(api); }
      return () => {
        listeners.delete(listener);
        // React Strict Mode can detach and immediately reattach a subscriber.
        // Delay disposal by one microtask, while still clearing account data on
        // an actual unmount/logout and ignoring its outstanding response.
        queueMicrotask(() => { if (!listeners.size) dispose(); });
      };
    },
    ensure() { return running || (snapshot.data ? Promise.resolve(snapshot.data) : refresh()); },
    refresh,
    setLiveState({ status = snapshot.status, pending = snapshot.pending }) {
      if (!disposed && (status !== snapshot.status || pending !== snapshot.pending)) publish({ ...snapshot, status, pending });
    },
    refreshToken(token) {
      if (token === undefined || Object.is(token, lastToken)) return running || Promise.resolve(snapshot.data);
      lastToken = token;
      return snapshot.data ? refresh() : (running || refresh());
    },
    dispose,
  };
  return api;
}
