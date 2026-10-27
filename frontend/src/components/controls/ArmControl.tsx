// Motorfreigabe: bewusste Handlung durch Gedrückthalten (0,8 s). Sperren genügt ein Tipp.
// Ist das Gerät nicht Steuerungsbesitzer, wird stattdessen die Übernahme angeboten.

import { Hand, Lock, LockOpen, OctagonX, RotateCcw, ShieldAlert } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { useIsOwner } from '../../hooks/common';
import { command } from '../../services/wsClient';
import { useVehicle } from '../../stores/vehicleStore';

const HOLD_MS = 800;

export function ArmControl({ compact = false }: { compact?: boolean }) {
  const vehicle = useVehicle((s) => s.telemetry?.vehicle);
  const session = useVehicle((s) => s.telemetry?.session);
  const hasFaults = useVehicle((s) => s.telemetry?.faults.some((f) => f.blocking && !f.active && f.code !== 'E010') ?? false);
  const owner = useIsOwner();
  const [progress, setProgress] = useState(0);
  const holdStart = useRef<number | null>(null);
  const raf = useRef(0);

  useEffect(() => () => cancelAnimationFrame(raf.current), []);

  const base = `flex items-center justify-center gap-2 whitespace-nowrap rounded-full border font-semibold transition select-none ${
    compact ? 'h-10 px-4 text-sm' : 'h-12 px-5 text-[15px]'
  }`;

  if (!vehicle || !session) {
    return <div className={`${base} border-line text-ink-3`}>Keine Verbindung</div>;
  }

  if (!owner) {
    const takeover = session.owner_present;
    return (
      <button
        type="button"
        data-testid="claim-control"
        disabled={takeover && !session.can_takeover}
        onClick={() => command(takeover ? 'takeover_control' : 'claim_control', {}, 'Dieses Gerät steuert jetzt')}
        className={`${base} border-accent bg-accent/15 text-accent shadow-glow-accent disabled:opacity-40`}
        title={takeover ? `Gesteuert von ${session.owner_device}` : undefined}
      >
        <Hand className="h-5 w-5" />
        {takeover ? (session.can_takeover ? 'Steuerung übernehmen' : 'Übernahme nur im Stillstand') : 'Steuerung übernehmen'}
      </button>
    );
  }

  if (vehicle.state === 'emergency_stop') {
    return (
      <button type="button" data-testid="estop-reset" onClick={() => command('estop_reset', {}, 'Not-Aus zurückgesetzt – Motoren bleiben gesperrt')} className={`${base} border-danger bg-danger-soft text-[#ffb3b8]`}>
        <OctagonX className="h-5 w-5" /> Not-Aus zurücksetzen
      </button>
    );
  }

  if (vehicle.state === 'fault') {
    return (
      <button
        type="button"
        data-testid="ack-faults"
        onClick={() => command('ack_faults', {}, 'Fehler quittiert')}
        className={`${base} border-danger/70 bg-danger-soft text-[#ffb3b8]`}
        title={hasFaults ? 'Behobene Fehler quittieren' : 'Fehler sind noch aktiv'}
      >
        <ShieldAlert className="h-5 w-5" /> Fehler quittieren
      </button>
    );
  }

  if (vehicle.armed) {
    return (
      <button
        type="button"
        data-testid="disarm"
        onClick={() => command('disarm')}
        className={`${base} border-ok/80 bg-ok-soft text-ok shadow-glow-ok`}
        title="Tippen zum Sperren"
      >
        <LockOpen className="h-5 w-5" /> Freigegeben
        {vehicle.neutral_required && <span className="text-xs font-normal text-warn">· Gas loslassen</span>}
      </button>
    );
  }

  const startHold = (e: React.PointerEvent) => {
    e.preventDefault();
    holdStart.current = performance.now();
    const step = () => {
      if (holdStart.current === null) return;
      const p = Math.min(1, (performance.now() - holdStart.current) / HOLD_MS);
      setProgress(p);
      if (p >= 1) {
        holdStart.current = null;
        setProgress(0);
        void command('arm', {}, 'Motoren freigegeben');
        return;
      }
      raf.current = requestAnimationFrame(step);
    };
    raf.current = requestAnimationFrame(step);
  };
  const endHold = () => {
    holdStart.current = null;
    cancelAnimationFrame(raf.current);
    setProgress(0);
  };

  return (
    <button
      type="button"
      data-testid="arm"
      onPointerDown={startHold}
      onPointerUp={endHold}
      onPointerLeave={endHold}
      onPointerCancel={endHold}
      onContextMenu={(e) => e.preventDefault()}
      className={`${base} relative overflow-hidden border-line-strong bg-bg-3 text-ink-2`}
      style={{ touchAction: 'none' }}
      aria-label="Gedrückt halten, um die Motoren freizugeben"
    >
      <span className="absolute inset-y-0 left-0 bg-ok/25" style={{ width: `${progress * 100}%` }} />
      <span className="relative flex items-center gap-2">
        {progress > 0 ? <RotateCcw className="h-5 w-5 animate-spin text-ok" /> : <Lock className="h-5 w-5" />}
        {compact ? 'Halten: Freigeben' : 'Gesperrt · Halten zum Freigeben'}
      </span>
    </button>
  );
}
