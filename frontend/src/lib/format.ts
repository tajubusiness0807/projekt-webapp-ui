// Formatierung auf Deutsch (Dezimalkomma, Einheiten mit schmalem Leerzeichen).

import type { Measurement, MeasurementStatus } from '../types/protocol';

const cache = new Map<number, Intl.NumberFormat>();

export function formatNumber(value: number, digits = 0): string {
  let fmt = cache.get(digits);
  if (!fmt) {
    fmt = new Intl.NumberFormat('de-DE', { minimumFractionDigits: digits, maximumFractionDigits: digits });
    cache.set(digits, fmt);
  }
  return fmt.format(value);
}

export function formatDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

export function formatHours(seconds: number): string {
  return formatNumber(seconds / 3600, 1);
}

export function formatClock(ts: number): string {
  return new Date(ts).toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

export function formatDateTime(ts: number): string {
  return new Date(ts).toLocaleString('de-DE', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
}

/** Ein Messwert ist nur „aktuell“, wenn er gemessen oder simuliert und frisch ist. */
export function isCurrent(m: Measurement | undefined | null, transportFresh = true): boolean {
  return !!m && transportFresh && m.value !== null && (m.status === 'valid' || m.status === 'simulated');
}

/** Berücksichtigt zusätzlich die Aktualität der Verbindung zum Backend. */
export function effectiveStatus(m: Measurement | undefined | null, transportFresh: boolean): MeasurementStatus {
  if (!m || m.value === null) return 'unavailable';
  if (!transportFresh) return 'stale';
  return m.status;
}

export function displayMeasurement(m: Measurement | undefined | null, digits = 0): string {
  if (!m || m.value === null) return '—';
  return formatNumber(m.value, digits);
}

export const STATUS_LABEL: Record<MeasurementStatus, string> = {
  valid: 'gemessen',
  simulated: 'simuliert',
  stale: 'veraltet',
  unavailable: 'nicht verfügbar',
};
