// Lenkzeile der Fahransicht: Neigungssteuerung (wenn aktiv) oder selbstzentrierender Lenkregler.

import { useDrag } from '@use-gesture/react';
import { Crosshair, Smartphone, SmartphoneNfc } from 'lucide-react';
import { useCallback, useEffect, useRef, useState } from 'react';
import { formatNumber } from '../../lib/format';
import { calibrateTilt, startTilt, stopTilt, useTilt } from '../../services/tiltController';
import { releaseInput, setInput, useInputView } from '../../stores/inputStore';
import { toast } from '../../stores/toastStore';
import { useLeaseRefresher } from './useLeaseRefresher';

export function SteeringControl({ disabled = false, showSlider = true }: { disabled?: boolean; showSlider?: boolean }) {
  const tilt = useTilt();
  const steer = useInputView((s) => s.steer);
  const trackRef = useRef<HTMLDivElement>(null);
  const [dragging, setDragging] = useState(false);
  const epoch = useInputView((s) => s.epoch);
  const epochAtStart = useRef(epoch);

  useLeaseRefresher(dragging && !tilt.active, ['steer']);

  const reset = useCallback(() => {
    setDragging(false);
    if (!useTilt.getState().active) releaseInput('steer');
  }, []);

  useEffect(() => {
    if (dragging && epoch !== epochAtStart.current) reset();
  }, [epoch, dragging, reset]);

  const bind = useDrag(
    ({ active, xy: [x], first, canceled }) => {
      if (disabled || tilt.active || canceled || !active) {
        reset();
        return;
      }
      if (first) epochAtStart.current = useInputView.getState().epoch;
      const rect = trackRef.current?.getBoundingClientRect();
      if (!rect) return;
      const rel = ((x - rect.left) / rect.width) * 2 - 1;
      setDragging(true);
      setInput('steer', Math.max(-1, Math.min(1, rel)), 'pedals');
    },
    { pointer: { capture: true }, filterTaps: false, preventDefault: true },
  );

  const toggleTilt = async () => {
    if (tilt.active) {
      stopTilt();
      return;
    }
    await startTilt();
    const state = useTilt.getState();
    if (state.error) toast.warning(state.error);
  };

  const pct = (steer + 1) * 50;
  return (
    <div className="flex w-full items-center gap-2 sm:gap-3">
      <button
        type="button"
        onClick={toggleTilt}
        disabled={disabled}
        className={`flex h-11 shrink-0 items-center gap-1.5 rounded-xl border px-2.5 text-xs font-medium transition ${
          tilt.active ? 'border-accent bg-accent/15 text-accent shadow-glow-accent' : 'border-line-strong bg-bg-2 text-ink-2'
        } disabled:opacity-40`}
        aria-pressed={tilt.active}
        title="Neigungssteuerung ein/aus"
      >
        {tilt.active ? <SmartphoneNfc className="h-4 w-4" /> : <Smartphone className="h-4 w-4" />}
        <span className="hidden sm:inline">Neigung</span>
      </button>

      {tilt.active || showSlider ? (
        <div
          ref={trackRef}
          {...(tilt.active ? {} : bind())}
          className={`relative h-11 min-w-0 flex-1 touch-none select-none rounded-xl border border-line bg-bg-2 ${disabled ? 'opacity-40' : ''}`}
          aria-label="Lenkung"
          data-testid="steering"
        >
          <div className="absolute inset-y-2 left-1/2 w-px bg-line-strong" />
          <div
            className="absolute inset-y-1.5 rounded-lg bg-accent/25"
            style={{ left: `${Math.min(pct, 50)}%`, width: `${Math.abs(pct - 50)}%` }}
          />
          <div
            className={`absolute top-1/2 h-8 w-8 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 ${
              tilt.active && !tilt.valid ? 'border-warn bg-warn/20' : 'border-accent bg-bg-4 shadow-glow-accent'
            }`}
            style={{ left: `${pct}%`, transition: dragging || tilt.active ? 'none' : 'left 150ms ease-out' }}
          />
          <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[11px] text-ink-3">L</span>
          <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-[11px] text-ink-3">R</span>
        </div>
      ) : (
        <div className="flex-1" />
      )}

      <div className="w-[4.5rem] shrink-0 text-right text-xs leading-tight text-ink-2">
        {tilt.active ? (
          tilt.valid ? (
            <>
              <div className="tabular-nums text-ink">{formatNumber(tilt.roll - tilt.calibration.roll, 0)}°</div>
              <div className="text-ink-3">Neigung</div>
            </>
          ) : (
            <div className="text-warn">Sensor ungültig</div>
          )
        ) : (
          <>
            <div className="tabular-nums text-ink">{formatNumber(Math.round(steer * 100))} %</div>
            <div className="text-ink-3">Lenkung</div>
          </>
        )}
      </div>
      {tilt.active && (
        <button
          type="button"
          onClick={() => (calibrateTilt() ? toast.success('Neutrallage gespeichert') : toast.warning('Keine gültigen Sensordaten'))}
          className="flex h-11 shrink-0 items-center gap-1 rounded-xl border border-line-strong bg-bg-2 px-2.5 text-xs text-ink-2"
          title="Aktuelle Haltung als Neutrallage speichern"
        >
          <Crosshair className="h-4 w-4" />
          <span className="hidden sm:inline">Kalibrieren</span>
        </button>
      )}
    </div>
  );
}
