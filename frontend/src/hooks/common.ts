import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { TELEMETRY_FRESH_MS, useVehicle } from '../stores/vehicleStore';

/** Aktualisiert periodisch (für Altersanzeigen und Aktualitätsprüfung). */
export function useNow(intervalMs = 500): number {
  const [now, setNow] = useState(() => performance.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(performance.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}

/** True, solange aktuelle Telemetrie ankommt. Andernfalls gelten alle Werte als veraltet. */
export function useTelemetryFresh(): boolean {
  const now = useNow(400);
  const conn = useVehicle((s) => s.conn);
  const last = useVehicle((s) => s.lastTelemetryAt);
  return conn === 'open' && now - last < TELEMETRY_FRESH_MS;
}

export function useIsOwner(): boolean {
  return useVehicle((s) => !!s.telemetry?.session.is_owner && s.conn === 'open');
}

/** Weicher Übergang eines Zahlenwerts (für Zeiger und Bögen), zeitbasiert über requestAnimationFrame. */
export function useSmoothed(target: number, timeConstantMs = 140): number {
  const [value, setValue] = useState(target);
  const current = useRef(target);
  const targetRef = useRef(target);
  targetRef.current = target;
  useEffect(() => {
    let raf = 0;
    let last = performance.now();
    const step = (t: number) => {
      const dt = t - last;
      last = t;
      const diff = targetRef.current - current.current;
      if (Math.abs(diff) > 0.001) {
        current.current += diff * (1 - Math.exp(-dt / timeConstantMs));
        setValue(current.current);
      } else if (current.current !== targetRef.current) {
        current.current = targetRef.current;
        setValue(current.current);
      }
      raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [timeConstantMs]);
  return value;
}

const mql = typeof window !== 'undefined' ? window.matchMedia('(min-width: 768px)') : null;

export function useIsWide(): boolean {
  return useSyncExternalStore(
    (cb) => {
      mql?.addEventListener('change', cb);
      return () => mql?.removeEventListener('change', cb);
    },
    () => mql?.matches ?? true,
  );
}
