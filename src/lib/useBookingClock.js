import { useEffect, useRef, useState } from 'react';
import { publicRpc } from './spa.js';

// Anchor to server time and advance with a monotonic clock, independent of device timezone/clock.
export function useBookingClock() {
  const [now, setNow] = useState(Date.now);
  const anchor = useRef(null);
  useEffect(() => {
    let live = true, syncing = false;
    const tick = () => {
      if (live) setNow(anchor.current ? anchor.current.epoch + performance.now() - anchor.current.at : Date.now());
    };
    async function sync() {
      if (syncing || document.visibilityState === 'hidden') return;
      syncing = true;
      const start = performance.now();
      try {
        const value = await publicRpc('spa_server_time');
        const epoch = Date.parse(value), end = performance.now();
        if (live && Number.isFinite(epoch)) { anchor.current = { epoch: epoch + (end - start) / 2, at: end }; tick(); }
      } catch { /* Keep the last successful server anchor while offline. */ }
      finally { syncing = false; }
    }
    sync();
    const timer = window.setInterval(tick, 1000);
    const calibrate = window.setInterval(sync, 60000);
    window.addEventListener('focus', sync);window.addEventListener('online', sync);
    document.addEventListener('visibilitychange', sync);
    return () => { live = false;window.clearInterval(timer);window.clearInterval(calibrate);window.removeEventListener('focus', sync);window.removeEventListener('online', sync);document.removeEventListener('visibilitychange', sync); };
  }, []);
  return now;
}
