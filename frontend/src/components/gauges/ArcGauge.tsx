// Halbkreis-/Bogeninstrument als SVG.
//
// * variant="hero": großer Tacho der Fahransicht (Bild 1) – Verlaufsbogen, Skala innen, leuchtender Zeiger.
// * variant="compact": Rundinstrument der Übersicht (Bild 2) – Fortschrittsbogen, Außenring.
// Ist kein gültiger Messwert vorhanden, steht der Zeiger auf null und die Anzeige sagt das deutlich.

import { useId } from 'react';
import { useSmoothed } from '../../hooks/common';
import { formatNumber } from '../../lib/format';
import type { MeasurementStatus } from '../../types/protocol';

const START = -125;
const END = 125;

function polar(cx: number, cy: number, r: number, angleDeg: number): [number, number] {
  const a = (angleDeg * Math.PI) / 180;
  return [cx + r * Math.sin(a), cy - r * Math.cos(a)];
}

function arcPath(cx: number, cy: number, r: number, from: number, to: number): string {
  const [x0, y0] = polar(cx, cy, r, from);
  const [x1, y1] = polar(cx, cy, r, to);
  const large = to - from > 180 ? 1 : 0;
  return `M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${r} ${r} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`;
}

export interface ArcGaugeProps {
  value: number | null;
  status: MeasurementStatus;
  max: number;
  majorStep: number;
  minorPerMajor?: number;
  unit: string;
  caption?: string;
  variant?: 'hero' | 'compact';
  colors?: [string, string, string];
  decimals?: number;
  className?: string;
  ariaLabel: string;
}

export function ArcGauge({
  value,
  status,
  max,
  majorStep,
  minorPerMajor = 5,
  unit,
  caption,
  variant = 'hero',
  colors = ['#22d3ee', '#2f8bff', '#1c4fd8'],
  decimals = 0,
  className = '',
  ariaLabel,
}: ArcGaugeProps) {
  const uid = useId().replace(/:/g, '');
  const usable = value !== null && (status === 'valid' || status === 'simulated');
  const target = usable ? Math.max(0, Math.min(max, value as number)) : 0;
  const smooth = useSmoothed(target, variant === 'hero' ? 160 : 200);
  const hero = variant === 'hero';

  const W = hero ? 640 : 400;
  const H = hero ? 500 : 400;
  const cx = W / 2;
  const cy = hero ? 300 : 200;
  const r = hero ? 262 : 150;
  const stroke = hero ? 13 : 9;
  const angle = START + ((END - START) * smooth) / max;

  const ticks: { v: number; major: boolean }[] = [];
  const minorStep = majorStep / minorPerMajor;
  for (let v = 0; v <= max + 1e-6; v += minorStep) {
    const rounded = Math.round(v * 1000) / 1000;
    ticks.push({ v: rounded, major: Math.abs(rounded / majorStep - Math.round(rounded / majorStep)) < 1e-6 });
  }

  const display = !usable ? '—' : formatNumber(value as number, decimals);
  const statusText =
    status === 'unavailable' ? 'Keine Messdaten' : status === 'stale' ? 'Messwert veraltet' : status === 'simulated' ? 'SIMULIERT' : null;

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      className={className}
      role="img"
      aria-label={`${ariaLabel}: ${usable ? `${display} ${unit}` : statusText}`}
      preserveAspectRatio="xMidYMid meet"
    >
      <defs>
        <linearGradient id={`g-${uid}`} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor={colors[0]} />
          <stop offset="0.55" stopColor={colors[1]} />
          <stop offset="1" stopColor={colors[2]} />
        </linearGradient>
        <radialGradient id={`halo-${uid}`} cx="50%" cy="50%" r="50%">
          <stop offset="0" stopColor="#13306a" stopOpacity="0.55" />
          <stop offset="0.6" stopColor="#0a1a3a" stopOpacity="0.25" />
          <stop offset="1" stopColor="#03060c" stopOpacity="0" />
        </radialGradient>
        <filter id={`glow-${uid}`} x="-30%" y="-30%" width="160%" height="160%">
          <feGaussianBlur stdDeviation={hero ? 7 : 5} result="b" />
          <feMerge>
            <feMergeNode in="b" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
        <linearGradient id={`needle-${uid}`} x1="0" y1="1" x2="0" y2="0">
          <stop offset="0" stopColor="#1c6dff" />
          <stop offset="1" stopColor="#4fe3ff" />
        </linearGradient>
      </defs>

      <circle cx={cx} cy={cy} r={r * 0.82} fill={`url(#halo-${uid})`} />
      {!hero && <circle cx={cx} cy={cy} r={r + 26} fill="none" stroke="#1a2942" strokeWidth="2" />}
      {!hero && <circle cx={cx} cy={cy} r={r + 32} fill="none" stroke="#0e1828" strokeWidth="6" />}

      {/* Spur und Wertbogen */}
      <path d={arcPath(cx, cy, r, START, END)} fill="none" stroke={hero ? `url(#g-${uid})` : '#16233a'} strokeOpacity={hero ? 0.22 : 1} strokeWidth={stroke} strokeLinecap="round" />
      {hero && <path d={arcPath(cx, cy, r + 20, START, END)} fill="none" stroke="#14233c" strokeWidth="2" />}
      {smooth > max * 0.002 && (
        <path
          d={arcPath(cx, cy, r, START, angle)}
          fill="none"
          stroke={`url(#g-${uid})`}
          strokeWidth={stroke}
          strokeLinecap="round"
          filter={`url(#glow-${uid})`}
          opacity={status === 'stale' ? 0.35 : 1}
        />
      )}

      {/* Skala */}
      {ticks.map(({ v, major }) => {
        const a = START + ((END - START) * v) / max;
        const outer = r - stroke / 2 - (hero ? 12 : 8);
        const inner = outer - (major ? (hero ? 26 : 14) : hero ? 12 : 6);
        const [x0, y0] = polar(cx, cy, outer, a);
        const [x1, y1] = polar(cx, cy, inner, a);
        const lit = usable && v <= smooth + 1e-6;
        return (
          <line
            key={v}
            x1={x0}
            y1={y0}
            x2={x1}
            y2={y1}
            stroke={lit ? (hero ? '#7fdcff' : '#5aa8ff') : major ? '#5c6f92' : '#34445f'}
            strokeWidth={major ? (hero ? 3.2 : 2.2) : hero ? 1.8 : 1.2}
            strokeLinecap="round"
          />
        );
      })}
      {ticks
        .filter((t) => t.major)
        .map(({ v }) => {
          const a = START + ((END - START) * v) / max;
          const [x, y] = polar(cx, cy, r - stroke / 2 - (hero ? 68 : 40), a);
          return (
            <text
              key={`l${v}`}
              x={x}
              y={y}
              textAnchor="middle"
              dominantBaseline="central"
              fill="#c9d6ea"
              fontSize={hero ? 25 : 17}
              fontWeight={500}
              className="tabular-nums"
            >
              {formatNumber(v, 0)}
            </text>
          );
        })}

      {/* Zeiger */}
      {hero && (
        <g transform={`rotate(${angle} ${cx} ${cy})`} opacity={usable ? 1 : 0.3} filter={`url(#glow-${uid})`}>
          <polygon
            points={`${cx - 7},${cy - 28} ${cx + 7},${cy - 28} ${cx + 1.6},${cy - r + 46} ${cx - 1.6},${cy - r + 46}`}
            fill={`url(#needle-${uid})`}
          />
        </g>
      )}

      {/* Zahlenwert */}
      <text
        x={cx}
        y={hero ? cy + 62 : cy + 6}
        textAnchor="middle"
        dominantBaseline="central"
        fill={usable ? '#f3f7ff' : '#5b6b86'}
        fontSize={hero ? 128 : 66}
        fontWeight={700}
        letterSpacing={hero ? -4 : -2}
        className="tabular-nums"
      >
        {display}
      </text>
      <text x={cx} y={hero ? cy + 142 : cy + 56} textAnchor="middle" fill="#7fb4ff" fontSize={hero ? 30 : 19} fontWeight={500}>
        {unit}
      </text>
      {statusText && (
        <text
          x={cx}
          y={hero ? cy + 178 : cy + 84}
          textAnchor="middle"
          fill={status === 'simulated' ? '#f6b73c' : status === 'stale' ? '#f6b73c' : '#8ea0bd'}
          fontSize={hero ? 17 : 13}
          fontWeight={600}
          letterSpacing="2"
        >
          {statusText}
        </text>
      )}
      {caption && (
        <text x={cx} y={H - 14} textAnchor="middle" fill="#a6b4cc" fontSize={hero ? 22 : 20}>
          {caption}
        </text>
      )}
    </svg>
  );
}
