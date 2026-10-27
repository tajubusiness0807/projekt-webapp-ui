// Darstellung eines Messwerts samt Zustand: veraltete oder fehlende Werte sehen nie wie aktuelle aus.

import { Clock3 } from 'lucide-react';
import { useTelemetryFresh } from '../../hooks/common';
import { displayMeasurement, effectiveStatus, STATUS_LABEL } from '../../lib/format';
import type { Measurement } from '../../types/protocol';

export function MeasurementValue({
  m,
  digits = 0,
  unit,
  className = '',
  showTag = true,
}: {
  m: Measurement | undefined | null;
  digits?: number;
  unit?: string;
  className?: string;
  showTag?: boolean;
}) {
  const fresh = useTelemetryFresh();
  const status = effectiveStatus(m, fresh);
  const text = status === 'unavailable' ? '—' : displayMeasurement(m, digits);
  const unitText = unit ?? m?.unit ?? '';
  return (
    <span
      className={`inline-flex items-baseline gap-1 tabular-nums ${status === 'stale' ? 'text-ink-3 line-through decoration-ink-4/60' : ''} ${
        status === 'unavailable' ? 'text-ink-3' : ''
      } ${className}`}
      title={`Status: ${STATUS_LABEL[status]}${m?.age_ms != null ? `, Alter ${m.age_ms} ms` : ''}`}
      data-status={status}
    >
      <span>{text}</span>
      {status !== 'unavailable' && unitText && <span className="text-[0.8em] font-normal text-ink-2">{unitText}</span>}
      {showTag && status === 'stale' && (
        <span className="ml-1 inline-flex items-center gap-0.5 self-center rounded border border-warn/50 px-1 text-[9px] font-semibold uppercase tracking-wide text-warn no-underline">
          <Clock3 className="h-2.5 w-2.5" /> veraltet
        </span>
      )}
      {showTag && status === 'unavailable' && (
        <span className="ml-1 self-center rounded border border-line-strong px-1 text-[9px] font-semibold uppercase tracking-wide text-ink-3">
          n. v.
        </span>
      )}
      {showTag && status === 'simulated' && (
        <span className="ml-1 self-center rounded border border-warn/40 px-1 text-[9px] font-semibold uppercase tracking-wide text-warn/90">
          sim
        </span>
      )}
    </span>
  );
}
