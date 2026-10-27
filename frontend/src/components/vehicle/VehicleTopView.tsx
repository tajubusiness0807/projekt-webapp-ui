// Draufsicht des Fahrzeugs. Leuchtstärke je Rad = vom Backend bestätigte (begrenzte) Motoranforderung.

import { DRIVE_MODE_BADGE } from '../../lib/labels';
import type { DriveModeName, WheelPair } from '../../types/protocol';

interface Props {
  front: WheelPair;
  rear: WheelPair;
  frontScale: number;
  rearScale: number;
  braking: boolean;
  mode: DriveModeName;
  className?: string;
}

function Wheel({ x, y, level, braking }: { x: number; y: number; level: number; braking: boolean }) {
  const glow = braking ? '#ff3d4a' : '#2f8bff';
  const intensity = braking ? 0.9 : Math.min(1, Math.abs(level));
  const stripX = x < 150 ? x + 50 : x - 10;
  return (
    <g>
      <rect x={x} y={y} width="46" height="88" rx="14" fill="url(#tire)" stroke="#2a3346" strokeWidth="1.5" />
      {Array.from({ length: 9 }, (_, i) => (
        <path key={i} d={`M ${x + 4} ${y + 10 + i * 8.5} l 38 3`} stroke="#1c2433" strokeWidth="3" strokeLinecap="round" />
      ))}
      <rect x={x + 14} y={y + 26} width="18" height="36" rx="5" fill="#1a2232" stroke="#3a4760" />
      <rect
        x={stripX}
        y={y + 14}
        width="6"
        height="60"
        rx="3"
        fill={glow}
        opacity={0.18 + 0.82 * intensity}
        style={{ filter: intensity > 0.05 ? `drop-shadow(0 0 ${4 + 8 * intensity}px ${glow})` : undefined, transition: 'opacity 120ms linear' }}
      />
    </g>
  );
}

function Chevrons({ x, y, visible }: { x: number; y: number; visible: boolean }) {
  return (
    <g opacity={visible ? 1 : 0.12} style={{ transition: 'opacity 200ms' }}>
      <path d={`M ${x - 9} ${y + 6} l 9 -9 l 9 9`} fill="none" stroke="#2f8bff" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round" />
      <path d={`M ${x - 9} ${y + 18} l 9 -9 l 9 9`} fill="none" stroke="#2f8bff" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round" opacity="0.7" />
    </g>
  );
}

export function VehicleTopView({ front, rear, frontScale, rearScale, braking, mode, className = '' }: Props) {
  const frontActive = !braking && Math.max(Math.abs(front.left), Math.abs(front.right)) > 0.02;
  const rearActive = !braking && Math.max(Math.abs(rear.left), Math.abs(rear.right)) > 0.02;
  return (
    <svg viewBox="0 0 300 380" className={className} role="img" aria-label={`Fahrzeug, Antrieb ${DRIVE_MODE_BADGE[mode]}`}>
      <defs>
        <linearGradient id="body" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#141b29" />
          <stop offset="0.5" stopColor="#273246" />
          <stop offset="1" stopColor="#141b29" />
        </linearGradient>
        <linearGradient id="tire" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#07090e" />
          <stop offset="0.5" stopColor="#151b26" />
          <stop offset="1" stopColor="#07090e" />
        </linearGradient>
        <radialGradient id="floor" cx="50%" cy="50%" r="55%">
          <stop offset="0" stopColor="#12305e" stopOpacity="0.45" />
          <stop offset="1" stopColor="#03060c" stopOpacity="0" />
        </radialGradient>
      </defs>
      <ellipse cx="150" cy="190" rx="140" ry="175" fill="url(#floor)" />
      {/* Achsen */}
      <rect x="80" y="86" width="140" height="8" rx="4" fill="#1d2738" />
      <rect x="80" y="286" width="140" height="8" rx="4" fill="#1d2738" />
      {/* Karosserie */}
      <path d="M108 30 Q150 14 192 30 L206 70 L206 312 Q150 348 94 312 L94 70 Z" fill="url(#body)" stroke="#36435c" strokeWidth="2" />
      <path d="M116 60 L184 60 L190 140 L110 140 Z" fill="#0b1019" stroke="#2c3850" />
      <path d="M112 150 L188 150 L188 270 L112 270 Z" fill="#101622" stroke="#2c3850" />
      <path d="M100 100 L200 100 M100 250 L200 250" stroke="#2c3850" strokeWidth="2" />
      <path d="M120 300 Q150 316 180 300" stroke="#3a4760" strokeWidth="2" fill="none" />
      {/* Antriebsmodus */}
      <rect x="118" y="188" width="64" height="30" rx="8" fill="#0a111e" stroke="#2f8bff" strokeOpacity="0.6" />
      <text x="150" y="208" textAnchor="middle" fill="#e9f0fb" fontSize="15" fontWeight="700" letterSpacing="1">
        {DRIVE_MODE_BADGE[mode]}
      </text>
      <Wheel x={34} y={46} level={front.left} braking={braking} />
      <Wheel x={220} y={46} level={front.right} braking={braking} />
      <Wheel x={34} y={246} level={rear.left} braking={braking} />
      <Wheel x={220} y={246} level={rear.right} braking={braking} />
      <Chevrons x={20} y={176} visible={frontActive && frontScale > 0} />
      <Chevrons x={280} y={176} visible={frontActive && frontScale > 0} />
      <Chevrons x={150} y={356} visible={rearActive && rearScale > 0} />
    </svg>
  );
}
