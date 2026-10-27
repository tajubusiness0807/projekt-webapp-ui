import { useEffect } from 'react';
import type { ChannelName } from '../../lib/deadman';
import { refreshInput } from '../../stores/inputStore';

/**
 * Erneuert die Totmann-Lease der angegebenen Kanäle bei jedem Frame, solange ``active`` gilt.
 * Stürzt die Komponente ab oder wird sie entfernt, endet die Erneuerung – der Wert verfällt.
 */
export function useLeaseRefresher(active: boolean, names: ChannelName[]): void {
  const key = names.join(',');
  useEffect(() => {
    if (!active) return;
    let raf = 0;
    const list = key.split(',') as ChannelName[];
    const loop = () => {
      list.forEach((n) => refreshInput(n));
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    // Fallback, falls requestAnimationFrame gedrosselt wird (z. B. Energiesparmodus)
    const timer = window.setInterval(() => list.forEach((n) => refreshInput(n)), 100);
    return () => {
      cancelAnimationFrame(raf);
      window.clearInterval(timer);
    };
  }, [active, key]);
}
