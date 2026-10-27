// Leistungsgewichtung vorne/hinten (Bild 2, Karte „Leistung“). Vorne + hinten = 100 %.

import { Minus, Plus } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useIsOwner } from '../../hooks/common';
import { formatNumber } from '../../lib/format';
import { command } from '../../services/wsClient';
import { useVehicle } from '../../stores/vehicleStore';

function AxleBox({
  title,
  value,
  accent,
  disabled,
  onChange,
  onCommit,
  min,
  max,
}: {
  title: string;
  value: number;
  accent: 'accent' | 'ok';
  disabled: boolean;
  onChange: (v: number) => void;
  onCommit: (v: number) => void;
  min: number;
  max: number;
}) {
  const color = accent === 'ok' ? 'var(--ok)' : 'var(--accent)';
  const pct = ((value - min) / Math.max(1, max - min)) * 100;
  return (
    <div className="flex flex-1 flex-col rounded-xl border border-line bg-bg-2/80 p-4">
      <div className="text-sm text-ink-2">{title}</div>
      <div className="mt-1 text-[32px] font-semibold tabular-nums text-ink">{formatNumber(value)} %</div>
      <input
        type="range"
        className={`range mt-3 w-full ${accent === 'ok' ? 'range-ok' : ''}`}
        aria-label={`${title} Gewichtung`}
        min={min}
        max={max}
        step={1}
        value={value}
        disabled={disabled}
        style={{ background: `linear-gradient(90deg, ${color} ${pct}%, var(--track) ${pct}%)` }}
        onChange={(e) => onChange(Number(e.target.value))}
        onPointerUp={(e) => onCommit(Number((e.target as HTMLInputElement).value))}
        onKeyUp={(e) => onCommit(Number((e.target as HTMLInputElement).value))}
      />
      <div className="mt-4 flex items-center justify-between rounded-xl border border-line-strong">
        <button type="button" className="px-4 py-2 text-ink-2 hover:text-ink disabled:opacity-40" disabled={disabled || value <= min} onClick={() => onCommit(Math.max(min, value - 5))} aria-label={`${title} verringern`}>
          <Minus className="h-5 w-5" />
        </button>
        <button type="button" className="px-4 py-2 text-ink-2 hover:text-ink disabled:opacity-40" disabled={disabled || value >= max} onClick={() => onCommit(Math.min(max, value + 5))} aria-label={`${title} erhöhen`}>
          <Plus className="h-5 w-5" />
        </button>
      </div>
    </div>
  );
}

export function PowerSplitControl() {
  const t = useVehicle((s) => s.telemetry);
  const settings = useVehicle((s) => s.settings);
  const caps = useVehicle((s) => s.capabilities);
  const owner = useIsOwner();
  const mode = t?.vehicle.drive_mode ?? 'awd';
  const target: 'awd' | 'custom' | null = mode === 'awd' ? 'awd' : mode === 'custom' ? 'custom' : null;
  const serverFront = t?.control.split.front_weight ?? 50;
  const [front, setFront] = useState(serverFront);
  useEffect(() => setFront(serverFront), [serverFront]);

  const distribution = caps?.axle_distribution.available ?? false;
  const disabled = !owner || target === null || !distribution;
  const [min, max] = target === 'awd' ? [20, 80] : [0, 100];

  const commitFront = (v: number) => {
    if (!target) return;
    const value = Math.max(min, Math.min(max, v));
    setFront(value);
    if (value !== (target === 'awd' ? settings?.power_split.awd_front_percent : settings?.power_split.custom_front_percent)) {
      void command('set_power_split', { target, front_percent: value });
    }
  };

  const out = t?.control.output;
  const frontReq = out ? Math.max(Math.abs(out.front.left), Math.abs(out.front.right)) : 0;
  const rearReq = out ? Math.max(Math.abs(out.rear.left), Math.abs(out.rear.right)) : 0;

  return (
    <div>
      <div className="flex gap-3">
        <AxleBox title="Vorne" value={front} accent="accent" disabled={disabled} min={min} max={max} onChange={setFront} onCommit={commitFront} />
        <AxleBox
          title="Hinten"
          value={100 - front}
          accent="ok"
          disabled={disabled}
          min={100 - max}
          max={100 - min}
          onChange={(v) => setFront(100 - v)}
          onCommit={(v) => commitFront(100 - v)}
        />
      </div>
      <p className="mt-3 text-xs leading-relaxed text-ink-3">
        Angeforderte Gewichtung. Begrenzte Motoranforderung jetzt: vorne {formatNumber(frontReq * 100)} %, hinten {formatNumber(rearReq * 100)} %.
        {!distribution && caps?.axle_distribution.reason ? ` Nicht verfügbar: ${caps.axle_distribution.reason}` : ''}
        {distribution && target === null ? ' Im Modus FWD/RWD ist die Verteilung fest.' : ''}
      </p>
    </div>
  );
}
