import { useCallback, useEffect, useMemo, useSyncExternalStore } from 'react';
import { rpc, errorText } from './spa.js';
import { subscribeLiveUpdates, getLiveConnectionStatus } from './useLiveRefresh.js';
import { createRefreshController } from './live-updates.js';
import { createOperationsSnapshotStore, EMPTY_OPERATIONS_SNAPSHOT } from './operations-snapshot.js';

const stores = new Map();
const subscribeDisabled = () => () => {};
const getDisabled = () => EMPTY_OPERATIONS_SNAPSHOT;

function storeForAccount(userKey) {
  if (!stores.has(userKey)) {
    const store = createOperationsSnapshotStore({
      read: () => rpc('spa_operations_convenience'),
      formatError: errorText,
      canRefresh: () => document.visibilityState !== 'hidden' && navigator.onLine !== false,
      connect: snapshotStore => {
        // A store owns one subscription, even when both the board and bell use
        // it. A broadcast therefore cannot become two identical RPC reads.
        const controller = createRefreshController({
          callback: () => snapshotStore.refresh(),
          canRefresh: () => document.visibilityState !== 'hidden' && navigator.onLine !== false,
          onPending: pending => snapshotStore.setLiveState({ pending }),
          debounceMs: 180,
        });
        snapshotStore.setLiveState({ status: getLiveConnectionStatus('operations') });
        const unsubscribe = subscribeLiveUpdates('operations', event => {
          if (event.type === 'status') snapshotStore.setLiveState({ status: event.status });
          else controller.invalidate();
        });
        return () => { unsubscribe(); controller.dispose(); };
      },
      onDispose: () => { if (stores.get(userKey) === store) stores.delete(userKey); },
    });
    stores.set(userKey, store);
  }
  return stores.get(userKey);
}

export function useOperationsSnapshot({ enabled = true, userKey, refreshToken } = {}) {
  const active = enabled && !!userKey;
  const store = useMemo(() => active ? storeForAccount(String(userKey)) : null, [active, userKey]);
  const snapshot = useSyncExternalStore(store?.subscribe || subscribeDisabled, store?.getSnapshot || getDisabled, getDisabled);
  const refresh = useCallback(() => store?.refresh() || Promise.resolve(null), [store]);
  useEffect(() => { store?.ensure(); store?.refreshToken(refreshToken); }, [store, refreshToken]);
  return { ...snapshot, refresh };
}
