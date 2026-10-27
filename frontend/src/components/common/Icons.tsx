// Eigene Symbole im Stil der Referenzbilder (Linienicons, 1,8 px Strich).

import type { SVGProps } from 'react';

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function base({ size = 24, ...rest }: IconProps) {
  return {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.8,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    'aria-hidden': true,
    ...rest,
  };
}

export function Logo({ size = 34, className }: { size?: number; className?: string }) {
  return (
    <svg width={size * 1.3} height={size} viewBox="0 0 52 40" className={className} aria-hidden>
      <defs>
        <linearGradient id="awc-logo" x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stopColor="#1c6dff" />
          <stop offset="1" stopColor="#22d3ee" />
        </linearGradient>
      </defs>
      <path d="M2 38 16 6h6.5L9 38z" fill="url(#awc-logo)" />
      <path d="M17 38 31 6h6.5L50 38h-7.5L34 16.5 24.5 38z" fill="url(#awc-logo)" />
      <path d="M26.5 30.5h12l-2.6-6h-6.8z" fill="url(#awc-logo)" opacity="0.55" />
    </svg>
  );
}

/** Bremsen-Warnsymbol: Kreis mit Ausrufezeichen und seitlichen Bögen. */
export function BrakeIcon(props: IconProps) {
  return (
    <svg {...base(props)} strokeWidth={props.strokeWidth ?? 2}>
      <circle cx="12" cy="12" r="6.2" />
      <path d="M12 8.6v4.2" />
      <path d="M12 15.6h.01" strokeWidth={2.8} />
      <path d="M4.6 6.2a9.6 9.6 0 0 0 0 11.6" />
      <path d="M19.4 6.2a9.6 9.6 0 0 1 0 11.6" />
    </svg>
  );
}

export function ChevronsUp(props: IconProps) {
  return (
    <svg {...base(props)}>
      <path d="m6 17 6-6 6 6" />
      <path d="m6 11 6-6 6 6" />
    </svg>
  );
}

export function ChevronsDown(props: IconProps) {
  return (
    <svg {...base(props)}>
      <path d="m6 7 6 6 6-6" />
      <path d="m6 13 6 6 6-6" />
    </svg>
  );
}

/** Achssymbol: Vorder- und Hinterachse mit Längswelle; aktive Achsen gefüllt. */
export function AxleIcon({ front = true, rear = true, ...props }: IconProps & { front?: boolean; rear?: boolean }) {
  return (
    <svg {...base(props)}>
      <path d="M12 5v14" />
      <path d="M7 6.5h10" />
      <path d="M7 17.5h10" />
      <rect x="4.2" y="4" width="2.8" height="5" rx="1" fill={front ? 'currentColor' : 'none'} />
      <rect x="17" y="4" width="2.8" height="5" rx="1" fill={front ? 'currentColor' : 'none'} />
      <rect x="4.2" y="15" width="2.8" height="5" rx="1" fill={rear ? 'currentColor' : 'none'} />
      <rect x="17" y="15" width="2.8" height="5" rx="1" fill={rear ? 'currentColor' : 'none'} />
      <circle cx="12" cy="12" r="1.4" fill="currentColor" />
    </svg>
  );
}

export function SpeedometerIcon(props: IconProps) {
  return (
    <svg {...base(props)}>
      <path d="M4.5 17.5a8.5 8.5 0 1 1 15 0" />
      <path d="m12 13 4-4.5" />
      <circle cx="12" cy="13.2" r="1.3" fill="currentColor" />
      <path d="M7.2 9.1 6 8M12 5.5V4M16.8 9.1 18 8" />
    </svg>
  );
}

export function SignalBars({ level, className }: { level: number; className?: string }) {
  // level 0…4
  return (
    <svg width="22" height="16" viewBox="0 0 22 16" className={className} aria-hidden>
      {[0, 1, 2, 3].map((i) => (
        <rect
          key={i}
          x={i * 5.5}
          y={12 - i * 3.6}
          width="3.6"
          height={4 + i * 3.6}
          rx="1"
          fill="currentColor"
          opacity={i < level ? 1 : 0.22}
        />
      ))}
    </svg>
  );
}

export function BatteryIcon({ percent, className, charging }: { percent: number | null; className?: string; charging?: boolean }) {
  const p = percent === null ? 0 : Math.max(0, Math.min(100, percent));
  const color = percent === null ? '#4a5a78' : p < 15 ? '#ff3d4a' : p < 30 ? '#f6b73c' : '#22e08a';
  return (
    <svg width="30" height="16" viewBox="0 0 30 16" className={className} aria-hidden>
      <rect x="1" y="1.5" width="25" height="13" rx="3" fill="none" stroke="currentColor" strokeWidth="1.6" />
      <rect x="27" y="5.5" width="2.2" height="5" rx="1" fill="currentColor" />
      <rect x="3.2" y="3.7" width={(20.6 * p) / 100} height="8.6" rx="1.6" fill={color} />
      {charging && <path d="M14 3.5 10.5 9h3l-1 3.5L16 7h-3z" fill="#03060c" />}
    </svg>
  );
}

export function BatteryTall({ percent, className }: { percent: number | null; className?: string }) {
  const p = percent === null ? 0 : Math.max(0, Math.min(100, percent));
  const color = percent === null ? '#4a5a78' : p < 15 ? '#ff3d4a' : p < 30 ? '#f6b73c' : '#22e08a';
  return (
    <svg width="20" height="32" viewBox="0 0 20 32" className={className} aria-hidden>
      <rect x="6.5" y="1" width="7" height="3" rx="1" fill="currentColor" />
      <rect x="1.5" y="3.5" width="17" height="27" rx="3.5" fill="none" stroke="currentColor" strokeWidth="1.8" />
      <rect x="4" y={6 + (22 * (100 - p)) / 100} width="12" height={(22 * p) / 100} rx="1.5" fill={color} />
    </svg>
  );
}
