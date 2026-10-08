import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from './spa.js';
import { createLiveUpdateBus, createRefreshController, isEditingDocument } from './live-updates.js';

const bus = createLiveUpdateBus(supabase);
export const subscribeLiveUpdates = (audience, listener) => bus.subscribe(audience, listener);
export const getLiveConnectionStatus = audience => bus.getStatus(audience);

export function useLiveConnectionStatus(audience = 'operations', enabled = true) {
  const [status, setStatus] = useState(enabled ? bus.getStatus(audience) : 'disabled');
  useEffect(() => {
    if (!enabled) { setStatus('disabled'); return; }
    return bus.subscribe(audience, event => { if (event.type === 'status') setStatus(event.status); });
  }, [audience, enabled]);
  return status;
}

export function useLiveRefresh(callback, { audience = 'operations', scopes = [], enabled = true, paused = false, debounceMs = 180, protectEditing = true } = {}) {
  const latest = useRef();
  latest.current = { callback, scopes, paused, protectEditing };
  const controller = useRef(null);
  const [state, setState] = useState({ status: enabled ? bus.getStatus(audience) : 'disabled', pending: false });
  useEffect(() => {
    if (!enabled) { setState({ status: 'disabled', pending: false }); return; }
    let mounted = true;
    const refresh = createRefreshController({
      callback: () => latest.current.callback(),
      canRefresh: () => !latest.current.paused && document.visibilityState !== 'hidden' && navigator.onLine !== false && (!latest.current.protectEditing || !isEditingDocument(document)),
      onPending: pending => { if (mounted) setState(previous => ({ ...previous, pending })); },
      debounceMs,
    });
    controller.current = refresh;
    const unsubscribe = bus.subscribe(audience, event => {
      if (!mounted) return;
      if (event.type === 'status') setState(previous => ({ ...previous, status: event.status }));
      else if (event.catchup || !latest.current.scopes.length || event.scopes.some(scope => latest.current.scopes.includes(scope))) refresh.invalidate();
    });
    // Focusout precedes activeElement settling, so wake on the next task.
    let focusTimer;
    const wake = () => refresh.resume();
    const focusout = () => { clearTimeout(focusTimer); focusTimer = setTimeout(wake, 0); };
    document.addEventListener('focusout', focusout);
    document.addEventListener('close', wake, true);
    document.addEventListener('visibilitychange', wake);
    window.addEventListener('online', wake);
    const observer = new MutationObserver(wake);
    observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['open', 'aria-modal'] });
    return () => {
      mounted = false;
      unsubscribe();
      refresh.dispose();
      clearTimeout(focusTimer);
      observer.disconnect();
      document.removeEventListener('focusout', focusout);
      document.removeEventListener('close', wake, true);
      document.removeEventListener('visibilitychange', wake);
      window.removeEventListener('online', wake);
      if (controller.current === refresh) controller.current = null;
    };
  }, [audience, enabled, debounceMs]);
  useEffect(() => { controller.current?.resume(); }, [paused, protectEditing]);
  const invalidate = useCallback(() => controller.current?.invalidate(), []);
  return { ...state, invalidate };
}
