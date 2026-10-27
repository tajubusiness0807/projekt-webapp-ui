// Gas- und Bremspedal als große Touchflächen mit Totmann-Verhalten.
//
// * Pointer Capture: Der Finger bleibt dem Pedal zugeordnet, auch wenn er die Fläche verlässt.
// * Loslassen, Abbruch (pointercancel), Verlust der Zuordnung, Fokusverlust → sofort 0.
// * Während gedrückt wird, erneuert jeder Frame die Lease; ohne Erneuerung verfällt der Wert.
// * Gas proportional zur Fingerhöhe (unten wenig, oben viel) oder „voll“ (Einstellung).

import { useCallback, useEffect, useRef, useState } from 'react';
import { BRAKE_LABEL } from '../../lib/labels';
import { pedalValue } from '../../lib/deadman';
import { formatNumber } from '../../lib/format';
import { held, releaseInput, setInput, useInputView } from '../../stores/inputStore';
import { useVehicle } from '../../stores/vehicleStore';
import { BrakeIcon, ChevronsDown, ChevronsUp } from '../common/Icons';
import { useLeaseRefresher } from './useLeaseRefresher';

interface PedalPadProps {
  kind: 'gas' | 'brake';
  disabled?: boolean;
  disabledReason?: string;
  className?: string;
}

export function PedalPad({ kind, disabled = false, disabledReason, className = '' }: PedalPadProps) {
  const channel = kind === 'gas' ? 'throttle' : 'brake';
  const ref = useRef<HTMLDivElement>(null);
  const pointerId = useRef<number | null>(null);
  const epochAtPress = useRef(0);
  const [pressed, setPressed] = useState(false);
  const value = useInputView((s) => s[channel]);
  const epoch = useInputView((s) => s.epoch);
  const tiltThrottle = useInputView((s) => s.tiltActive) && useVehicle.getState().settings?.tilt.pitch_function === 'throttle';
  const pedalMode = useVehicle((s) => s.settings?.ui.pedal_mode ?? 'proportional');
  const haptics = useVehicle((s) => s.settings?.ui.haptic_feedback ?? true);
  const brakeState = useVehicle((s) => s.telemetry?.vehicle.brake_state);

  useLeaseRefresher(pressed, [channel]);

  const release = useCallback(() => {
    if (pointerId.current !== null && ref.current?.hasPointerCapture?.(pointerId.current)) {
      try {
        ref.current.releasePointerCapture(pointerId.current);
      } catch {
        /* bereits freigegeben */
      }
    }
    pointerId.current = null;
    held[kind] = false;
    releaseInput(channel);
    setPressed(false);
  }, [channel, kind]);

  // Globales Zurücksetzen (Verbindungsverlust, Fokusverlust, Fehler) → Pedal muss neu gedrückt werden.
  useEffect(() => {
    if (pressed && epoch !== epochAtPress.current) release();
  }, [epoch, pressed, release]);

  useEffect(() => {
    if (disabled && pressed) release();
  }, [disabled, pressed, release]);

  useEffect(() => release, [release]);

  const update = (clientY: number) => {
    const el = ref.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const rel = (rect.bottom - clientY) / rect.height;
    if (kind === 'brake') {
      setInput('brake', 1, 'pedals');
    } else if (!tiltThrottle) {
      setInput('throttle', pedalValue(rel, pedalMode), 'pedals');
    }
  };

  const onPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (disabled || pointerId.current !== null) return;
    e.preventDefault();
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      /* ältere Browser */
    }
    pointerId.current = e.pointerId;
    epochAtPress.current = useInputView.getState().epoch;
    held[kind] = true;
    setPressed(true);
    update(e.clientY);
    if (haptics && 'vibrate' in navigator) navigator.vibrate?.(12);
  };

  const onPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (e.pointerId === pointerId.current) update(e.clientY);
  };

  const onPointerEnd = (e: React.PointerEvent<HTMLDivElement>) => {
    if (e.pointerId === pointerId.current) release();
  };

  const isGas = kind === 'gas';
  const fill = Math.round(value * 100);
  const active = pressed && value > 0;
  const brakeText = !isGas && pressed && brakeState ? BRAKE_LABEL[brakeState] : null;

  return (
    <div
      ref={ref}
      role="button"
      aria-label={isGas ? 'Gas (gedrückt halten)' : 'Bremse (gedrückt halten)'}
      aria-pressed={pressed}
      aria-disabled={disabled}
      data-testid={isGas ? 'pedal-gas' : 'pedal-brake'}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerEnd}
      onPointerCancel={onPointerEnd}
      onLostPointerCapture={onPointerEnd}
      onContextMenu={(e) => e.preventDefault()}
      className={`pedal relative flex select-none flex-col items-center justify-center overflow-hidden rounded-pad border-2 ${
        isGas ? 'pedal-gas' : 'pedal-brake'
      } ${active ? 'pedal-active' : ''} ${disabled ? 'pedal-disabled' : ''} ${className}`}
    >
      {/* Füllstand = angeforderte Stellung */}
      <div
        className={`pointer-events-none absolute inset-x-0 bottom-0 ${isGas ? 'bg-ok/20' : 'bg-danger/20'}`}
        style={{ height: `${active ? fill : 0}%`, transition: 'height 60ms linear' }}
      />
      <div className="pointer-events-none relative flex flex-1 flex-col items-center justify-center gap-[6%]">
        {isGas ? (
          <ChevronsUp className="pedal-icon text-ok" strokeWidth={2.4} />
        ) : (
          <BrakeIcon className="pedal-icon text-danger" strokeWidth={2.2} />
        )}
        <span className="pedal-label font-semibold tracking-tight text-ink">{isGas ? 'Gas' : 'Bremse'}</span>
        <span className={`pedal-value tabular-nums ${active ? (isGas ? 'text-ok' : 'text-danger') : 'text-transparent'}`}>
          {isGas ? `${formatNumber(fill)} %` : 'aktiv'}
        </span>
      </div>
      <div className="pointer-events-none relative mb-[8%] flex min-h-[2.5em] flex-col items-center justify-end px-2 text-center">
        {brakeText && <span className="mb-1 text-[11px] leading-tight text-[#ffb3b8]">{brakeText}</span>}
        {disabled && disabledReason && <span className="mb-1 text-[11px] leading-tight text-ink-3">{disabledReason}</span>}
        {isGas ? <ChevronsUp className="h-7 w-7 text-ok/90" /> : <ChevronsDown className="h-7 w-7 text-danger/90" />}
      </div>
    </div>
  );
}
