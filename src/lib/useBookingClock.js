import { useEffect, useRef, useState } from 'react';
import { publicRpc } from './spa.js';

// Anchor to server time, then wake only when a displayed booking boundary or
// Taiwan midnight is reached. Re-entering the page calibrates after time away.
export function useBookingClock(boundaries = []) {
  const [now, setNow] = useState(Date.now);
  const anchor = useRef(null);
  const read = () => anchor.current ? anchor.current.epoch + performance.now() - anchor.current.at : Date.now();
  const boundaryKey = boundaries.map(value => typeof value === 'number' ? value : Date.parse(value)).filter(Number.isFinite).sort((a, b) => a - b).join(',');
  useEffect(() => {
    let live = true, syncing = false;
    async function sync() {
      if (syncing || document.visibilityState === 'hidden') return;
      syncing = true;
      setNow(read());
      const start = performance.now();
      try {
        const value = await publicRpc('spa_server_time');
        const epoch = Date.parse(value), end = performance.now();
        if (live && Number.isFinite(epoch)) {
          anchor.current = { epoch: epoch + (end - start) / 2, at: end };
          setNow(read());
        }
      } catch { /* Keep the last successful server anchor while offline. */ }
      finally { syncing = false; }
    }
    sync();
    window.addEventListener('focus', sync);
    window.addEventListener('online', sync);
    document.addEventListener('visibilitychange', sync);
    return () => {
      live = false;
      window.removeEventListener('focus', sync);
      window.removeEventListener('online', sync);
      document.removeEventListener('visibilitychange', sync);
    };
  }, []);
  useEffect(() => {
    const current = read(), day = 86400000, taiwanOffset = 8 * 3600000;
    if (boundaryKey.split(',').map(Number).some(value => value > now && value <= current)) { setNow(current); return; }
    const midnight = (Math.floor((current + taiwanOffset) / day) + 1) * day - taiwanOffset;
    const next = Math.min(midnight, ...boundaryKey.split(',').map(Number).filter(value => value > current));
    const timer = window.setTimeout(() => setNow(read()), Math.max(1, next - current + 1));
    return () => window.clearTimeout(timer);
  }, [now, boundaryKey]);
  return now;
}
