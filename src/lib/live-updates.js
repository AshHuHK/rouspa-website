// Database broadcasts carry only generic scopes. Business data still comes from
// the existing permission-checked RPCs; never subscribe to raw row changes.
export const LIVE_TOPICS = Object.freeze({ operations: 'rou-spa:operations', public: 'rou-spa:public' });
export const LIVE_SCOPES = new Set(['appointments', 'checkouts', 'orders', 'inventory', 'reviews', 'coupons', 'schedule', 'payroll', 'attendance', 'settings', 'team', 'catalog', 'customers', 'balances', 'sales', 'audit', 'hours', 'availability', 'member']);
const PUBLIC_SCOPES = new Set(['catalog', 'hours', 'availability', 'member']);

export function createLiveUpdateBus(client, { window: win = globalThis.window, document: doc = globalThis.document } = {}) {
  const audiences = new Map();
  function get(audience) {
    if (!LIVE_TOPICS[audience]) throw new Error('Unknown live update audience');
    if (!audiences.has(audience)) audiences.set(audience, { audience, listeners: new Set(), status: 'disconnected', channel: null, generation: 0 });
    return audiences.get(audience);
  }
  function notify(entry, event) {
    for (const listener of [...entry.listeners]) listener(event);
  }
  function status(entry, value) {
    entry.status = value;
    notify(entry, { type: 'status', status: value });
  }
  function stop(entry) {
    entry.generation++;
    if (entry.channel) void client.removeChannel(entry.channel);
    entry.channel = null;
  }
  async function connect(entry) {
    stop(entry);
    if (!entry.listeners.size) return;
    if (win?.navigator?.onLine === false) { status(entry, 'offline'); return; }
    const generation = entry.generation;
    status(entry, 'connecting');
    try {
      if (entry.audience === 'operations') {
        const { data, error } = await client.auth.getSession();
        if (generation !== entry.generation || !entry.listeners.size) return;
        if (error) throw error;
        if (!data?.session?.access_token) { status(entry, 'unauthenticated'); return; }
        await client.realtime.setAuth(data.session.access_token);
      }
      if (generation !== entry.generation || !entry.listeners.size) return;
      entry.channel = client.channel(LIVE_TOPICS[entry.audience], { config: { private: entry.audience === 'operations' } })
        .on('broadcast', { event: 'invalidate' }, ({ payload }) => {
          if (generation !== entry.generation || !Array.isArray(payload?.scopes)) return;
          const allowed = entry.audience === 'public' ? PUBLIC_SCOPES : LIVE_SCOPES;
          const scopes = [...new Set(payload.scopes.filter(scope => allowed.has(scope)))];
          if (scopes.length) notify(entry, { type: 'invalidate', scopes });
        })
        .subscribe(value => {
          if (generation !== entry.generation) return;
          const next = value === 'SUBSCRIBED' ? 'connected' : value === 'CHANNEL_ERROR' || value === 'TIMED_OUT' ? 'error' : 'disconnected';
          status(entry, next);
          // Every join closes the gap between the initial RPC and subscription,
          // and catches up after Realtime's own reconnect. No timer polls data.
          if (next === 'connected') notify(entry, { type: 'invalidate', scopes: [], catchup: true });
        });
    } catch {
      if (generation === entry.generation) status(entry, 'error');
    }
  }
  let authSubscription;
  let attached = false;
  const online = () => { for (const entry of audiences.values()) if (entry.listeners.size) void connect(entry); };
  const offline = () => { for (const entry of audiences.values()) if (entry.listeners.size) { stop(entry); status(entry, 'offline'); } };
  const visible = () => {
    if (doc?.visibilityState === 'hidden') return;
    for (const entry of audiences.values()) if (entry.listeners.size) {
      if (!entry.channel && entry.status !== 'unauthenticated') void connect(entry);
      notify(entry, { type: 'invalidate', scopes: [], catchup: true });
    }
  };
  function attach() {
    if (attached) return;
    attached = true;
    win?.addEventListener('online', online);
    win?.addEventListener('offline', offline);
    win?.addEventListener('focus', visible);
    doc?.addEventListener('visibilitychange', visible);
    authSubscription = client.auth.onAuthStateChange((event) => {
      if (!['SIGNED_IN', 'SIGNED_OUT', 'TOKEN_REFRESHED', 'USER_UPDATED'].includes(event)) return;
      // Avoid invoking another Auth method while its callback holds the lock.
      queueMicrotask(() => {
        const entry = audiences.get('operations');
        if (!entry?.listeners.size) return;
        void connect(entry);
        notify(entry, { type: 'invalidate', scopes: [], catchup: true });
      });
    }).data.subscription;
  }
  function detach() {
    if ([...audiences.values()].some(entry => entry.listeners.size)) return;
    win?.removeEventListener('online', online);
    win?.removeEventListener('offline', offline);
    win?.removeEventListener('focus', visible);
    doc?.removeEventListener('visibilitychange', visible);
    authSubscription?.unsubscribe();
    authSubscription = null;
    attached = false;
  }
  return {
    subscribe(audience, listener) {
      const entry = get(audience);
      entry.listeners.add(listener);
      attach();
      listener({ type: 'status', status: entry.status });
      if (entry.listeners.size === 1) void connect(entry);
      return () => {
        entry.listeners.delete(listener);
        if (!entry.listeners.size) { stop(entry); entry.status = 'disconnected'; }
        detach();
      };
    },
    getStatus(audience) { return get(audience).status; },
  };
}

// Small independent state machine: debounces bursts, serializes async fetches,
// and keeps one queued refresh while hidden, editing, paused or already busy.
export function createRefreshController({ callback, canRefresh = () => true, onPending = () => {}, debounceMs = 180, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let disposed = false, pending = false, running = false, timer = null;
  function mark(value) { if (pending !== value) { pending = value; onPending(value); } }
  function schedule() {
    if (disposed || !pending || running || !canRefresh() || timer !== null) return;
    timer = setTimer(() => { timer = null; void flush(); }, debounceMs);
  }
  async function flush() {
    if (disposed || !pending || running || !canRefresh()) return;
    running = true;
    mark(false);
    try { await callback(); } catch { /* RPC owners display their own errors. */ }
    finally { running = false; if (!disposed) schedule(); }
  }
  return {
    invalidate() { if (!disposed) { mark(true); schedule(); } },
    resume: schedule,
    dispose() { disposed = true; if (timer !== null) clearTimer(timer); timer = null; },
    get pending() { return pending; },
  };
}

export function isEditingDocument(doc = globalThis.document) {
  const active = doc?.activeElement;
  return Boolean(active?.matches?.('input,textarea,select,[contenteditable=""],[contenteditable="true"]') || active?.isContentEditable || doc?.querySelector?.('dialog[open],[role="dialog"][aria-modal="true"]'));
}
