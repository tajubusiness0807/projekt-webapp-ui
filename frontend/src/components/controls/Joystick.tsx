// Joystick der Übersicht: hoch = Gas, runter = Bremse, seitlich = Lenkung. Loslassen → Mitte → alles 0.

import { useDrag } from '@use-gesture/react';
import { useCallback, useEffect, useRef, useState } from 'react';
import { releaseInput, setInput, useInputView } from '../../stores/inputStore';
import { useLeaseRefresher } from './useLeaseRefresher';

const BRAKE_THRESHOLD = 0.2;
const GAS_THRESHOLD = 0.08;

export function Joystick({ disabled = false, size = 220 }: { disabled?: boolean; size?: number }) {
  const [knob, setKnob] = useState({ x: 0, y: 0 });
  const [active, setActive] = useState(false);
  const epoch = useInputView((s) => s.epoch);
  const epochAtStart = useRef(epoch);
  const radius = size * 0.34;

  useLeaseRefresher(active, ['throttle', 'brake', 'steer']);

  const reset = useCallback(() => {
    setActive(false);
    setKnob({ x: 0, y: 0 });
    releaseInput('throttle');
    releaseInput('brake');
    releaseInput('steer');
  }, []);

  useEffect(() => {
    if (active && epoch !== epochAtStart.current) reset();
  }, [epoch, active, reset]);

  useEffect(() => {
    if (disabled && active) reset();
  }, [disabled, active, reset]);

  useEffect(() => reset, [reset]);

  const bind = useDrag(
    ({ active: dragging, movement: [mx, my], first, canceled }) => {
      if (disabled || canceled || !dragging) {
        reset();
        return;
      }
      if (first) epochAtStart.current = useInputView.getState().epoch;
      const len = Math.hypot(mx, my);
      const k = len > radius ? radius / len : 1;
      const x = mx * k;
      const y = my * k;
      setKnob({ x, y });
      setActive(true);
      const nx = x / radius;
      const ny = -y / radius;
      if (ny < -BRAKE_THRESHOLD) {
        releaseInput('throttle');
        setInput('brake', Math.min(1, (-ny - BRAKE_THRESHOLD) / (1 - BRAKE_THRESHOLD) + 0.3), 'joystick');
      } else {
        releaseInput('brake');
        if (ny > GAS_THRESHOLD) setInput('throttle', (ny - GAS_THRESHOLD) / (1 - GAS_THRESHOLD), 'joystick');
        else releaseInput('throttle');
      }
      if (Math.abs(nx) > 0.05) setInput('steer', nx, 'joystick');
      else releaseInput('steer');
    },
    { pointer: { capture: true, keys: false }, filterTaps: false, preventDefault: true },
  );

  const arrow = 'fill-ink-2';
  return (
    <div
      className={`relative shrink-0 touch-none select-none ${disabled ? 'opacity-40' : ''}`}
      style={{ width: size, height: size }}
      data-testid="joystick"
      aria-label="Joystick: hoch Gas, runter Bremse, seitlich Lenkung"
    >
      <svg viewBox="0 0 200 200" className="absolute inset-0 h-full w-full" aria-hidden>
        <defs>
          <radialGradient id="joy-base" cx="50%" cy="45%" r="60%">
            <stop offset="0" stopColor="#0f1a2c" />
            <stop offset="1" stopColor="#070d18" />
          </radialGradient>
        </defs>
        <circle cx="100" cy="100" r="96" fill="url(#joy-base)" stroke="#22324e" strokeWidth="2" />
        <circle cx="100" cy="100" r="70" fill="none" stroke="#172640" strokeWidth="1.5" />
        <polygon points="100,14 92,26 108,26" className={arrow} />
        <polygon points="100,186 92,174 108,174" className={arrow} />
        <polygon points="14,100 26,92 26,108" className={arrow} />
        <polygon points="186,100 174,92 174,108" className={arrow} />
      </svg>
      <div
        {...bind()}
        className={`absolute left-1/2 top-1/2 rounded-full ${disabled ? 'cursor-not-allowed' : 'cursor-grab active:cursor-grabbing'}`}
        style={{
          width: size * 0.34,
          height: size * 0.34,
          transform: `translate(calc(-50% + ${knob.x}px), calc(-50% + ${knob.y}px))`,
          transition: active ? 'none' : 'transform 160ms ease-out',
          background: 'radial-gradient(circle at 35% 30%, #5aa8ff 0%, #2f7bff 35%, #1546c2 75%, #0c2c7e 100%)',
          boxShadow: active ? '0 0 26px rgba(47,139,255,0.65)' : '0 0 16px rgba(47,139,255,0.35)',
          touchAction: 'none',
        }}
      />
    </div>
  );
}
