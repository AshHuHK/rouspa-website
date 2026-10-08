import { useCallback, useEffect, useRef, useState } from 'react';
import { errorText, publicRpc, taipeiDate } from './spa.js';
import { createPublicDataController } from './public-data.js';
import { useLiveRefresh } from './useLiveRefresh.js';
import { useBookingClock } from './useBookingClock.js';

export function usePublicData(name, { args = {}, scopes = [], initialData = null, enabled = true, paused = false, lang = 'zh' } = {}) {
  const argsKey = JSON.stringify(args);
  const latest = useRef();
  latest.current = { args };
  const controller = useRef(null);
  const [state, setState] = useState({ data: initialData, error: null, loading: enabled });
  const refresh = useCallback(() => controller.current?.refresh() || Promise.resolve(null), []);
  useEffect(() => {
    if (!enabled) return;
    const current = createPublicDataController({
      read: () => publicRpc(name, latest.current.args),
      onResult: data => setState(previous => ({ ...previous, data, error: null })),
      onError: error => setState(previous => ({ ...previous, error })),
      onLoading: loading => setState(previous => ({ ...previous, loading })),
    });
    controller.current = current;
    void current.refresh();
    return () => { current.dispose(); if (controller.current === current) controller.current = null; };
  }, [name, argsKey, enabled]);
  const live = useLiveRefresh(refresh, { audience: 'public', scopes, enabled, paused, protectEditing: false });
  return { ...state, error: state.error ? errorText(state.error, lang) : '', refresh, status: live.status, pending: live.pending };
}

export function usePublicCatalog({ lang = 'zh', enabled = true, paused = false } = {}) {
  const resource = usePublicData('spa_catalog', { lang, enabled, paused, scopes: ['catalog', 'hours'] });
  // Hours change at Taiwan midnight even if no database record changed. The
  // booking clock wakes only at that boundary or when the page returns.
  const now = useBookingClock();
  const day = taipeiDate(new Date(now)), previousDay = useRef(day);
  useEffect(() => {
    if (previousDay.current === day) return;
    previousDay.current = day;
    if (enabled) void resource.refresh();
  }, [day, enabled, resource.refresh]);
  return resource;
}
