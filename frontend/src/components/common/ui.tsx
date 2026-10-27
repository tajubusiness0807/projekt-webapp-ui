// Basis-Bausteine: Karte, Schalter, Regler, Segmentauswahl, Hinweis, Abzeichen.

import { Lock } from 'lucide-react';
import { useId, type ReactNode } from 'react';
import { formatNumber } from '../../lib/format';

export function Card({
  title,
  action,
  children,
  className = '',
  padded = true,
}: {
  title?: ReactNode;
  action?: ReactNode;
  children: ReactNode;
  className?: string;
  padded?: boolean;
}) {
  return (
    <section className={`card ${padded ? 'p-4 sm:p-5' : ''} ${className}`}>
      {(title || action) && (
        <header className="mb-3 flex items-center justify-between gap-3">
          {title && <h2 className="text-[17px] font-semibold tracking-tight text-ink">{title}</h2>}
          {action}
        </header>
      )}
      {children}
    </section>
  );
}

export function Toggle({
  checked,
  onChange,
  disabled,
  locked,
  label,
}: {
  checked: boolean;
  onChange?: (value: boolean) => void;
  disabled?: boolean;
  locked?: boolean;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled || locked}
      onClick={() => onChange?.(!checked)}
      className={`relative inline-flex h-7 w-12 shrink-0 items-center rounded-full border transition-colors duration-200 ${
        checked ? 'border-accent bg-accent' : 'border-line-strong bg-bg-3'
      } ${disabled ? 'opacity-40' : ''} ${locked ? 'cursor-not-allowed' : 'cursor-pointer'}`}
    >
      <span
        className={`absolute top-[3px] h-5 w-5 rounded-full bg-white shadow transition-transform duration-200 ${
          checked ? 'translate-x-[22px]' : 'translate-x-[3px]'
        }`}
      />
      {locked && <Lock className="absolute -right-5 h-3.5 w-3.5 text-ink-3" />}
    </button>
  );
}

export function RangeField({
  label,
  value,
  min,
  max,
  step = 1,
  unit = '',
  digits = 0,
  onChange,
  onCommit,
  disabled,
  hint,
  accent = 'accent',
  icon,
}: {
  label: ReactNode;
  value: number;
  min: number;
  max: number;
  step?: number;
  unit?: string;
  digits?: number;
  onChange: (value: number) => void;
  onCommit?: (value: number) => void;
  disabled?: boolean;
  hint?: ReactNode;
  accent?: 'accent' | 'ok';
  icon?: ReactNode;
}) {
  const id = useId();
  const pct = ((value - min) / (max - min)) * 100;
  const color = accent === 'ok' ? 'var(--ok)' : 'var(--accent)';
  return (
    <div className={`py-1.5 ${disabled ? 'opacity-50' : ''}`}>
      <div className="flex items-center gap-3">
        {icon && <span className="text-ink-2">{icon}</span>}
        <label htmlFor={id} className="min-w-0 flex-1 text-sm text-ink-2">
          {label}
        </label>
        <div className="flex items-center gap-1">
          <input
            type="number"
            inputMode="decimal"
            aria-label={`${typeof label === 'string' ? label : 'Wert'} (Zahl)`}
            className="input-number w-[4.5rem]"
            value={Number.isFinite(value) ? Number(value.toFixed(digits)) : ''}
            min={min}
            max={max}
            step={step}
            disabled={disabled}
            onChange={(e) => {
              const v = Number(e.target.value);
              if (Number.isFinite(v)) onChange(Math.min(max, Math.max(min, v)));
            }}
            onBlur={(e) => {
              const v = Number(e.target.value);
              if (Number.isFinite(v)) onCommit?.(Math.min(max, Math.max(min, v)));
            }}
          />
          {unit && <span className="w-10 text-xs text-ink-3">{unit}</span>}
        </div>
      </div>
      <input
        id={id}
        type="range"
        className="range mt-2 w-full"
        min={min}
        max={max}
        step={step}
        value={value}
        disabled={disabled}
        style={{ background: `linear-gradient(90deg, ${color} ${pct}%, var(--track) ${pct}%)` }}
        onChange={(e) => onChange(Number(e.target.value))}
        onPointerUp={(e) => onCommit?.(Number((e.target as HTMLInputElement).value))}
        onKeyUp={(e) => onCommit?.(Number((e.target as HTMLInputElement).value))}
      />
      {hint && <p className="mt-1 text-xs text-ink-3">{hint}</p>}
    </div>
  );
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
  disabled,
  size = 'md',
}: {
  value: T;
  options: { value: T; label: ReactNode; disabled?: boolean; title?: string }[];
  onChange: (value: T) => void;
  disabled?: boolean;
  size?: 'sm' | 'md';
}) {
  return (
    <div className={`inline-flex rounded-xl border border-line bg-bg-2 p-1 ${disabled ? 'opacity-50' : ''}`} role="radiogroup">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          title={o.title}
          disabled={disabled || o.disabled}
          onClick={() => onChange(o.value)}
          className={`rounded-lg font-medium transition-colors ${size === 'sm' ? 'px-2.5 py-1 text-xs' : 'px-3.5 py-1.5 text-sm'} ${
            value === o.value ? 'bg-accent text-white shadow-glow-accent' : 'text-ink-2 hover:text-ink'
          } disabled:cursor-not-allowed disabled:opacity-40`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Notice({ kind = 'info', children }: { kind?: 'info' | 'warning' | 'danger' | 'ok'; children: ReactNode }) {
  const styles = {
    info: 'border-accent/30 bg-accent-soft/40 text-ink-2',
    warning: 'border-warn/40 bg-warn-soft/60 text-warn',
    danger: 'border-danger/40 bg-danger-soft/60 text-[#ff8a92]',
    ok: 'border-ok/30 bg-ok-soft/50 text-ok',
  }[kind];
  return <div className={`rounded-xl border px-3.5 py-2.5 text-sm leading-relaxed ${styles}`}>{children}</div>;
}

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: 'neutral' | 'ok' | 'warn' | 'danger' | 'accent' }) {
  const styles = {
    neutral: 'border-line-strong text-ink-2',
    ok: 'border-ok/50 text-ok',
    warn: 'border-warn/60 text-warn',
    danger: 'border-danger/60 text-danger',
    accent: 'border-accent/60 text-accent',
  }[tone];
  return (
    <span className={`inline-flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider ${styles}`}>
      {children}
    </span>
  );
}

export function Row({ label, children, hint }: { label: ReactNode; children: ReactNode; hint?: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-line/60 py-2.5 last:border-0">
      <div className="min-w-0">
        <div className="text-sm text-ink-2">{label}</div>
        {hint && <div className="text-xs text-ink-3">{hint}</div>}
      </div>
      <div className="shrink-0 text-right text-sm text-ink">{children}</div>
    </div>
  );
}

export function KeyValue({ label, value, digits = 0, unit }: { label: string; value: number | null | undefined; digits?: number; unit?: string }) {
  return (
    <Row label={label}>
      <span className="tabular-nums">{value === null || value === undefined ? '—' : `${formatNumber(value, digits)}${unit ? ` ${unit}` : ''}`}</span>
    </Row>
  );
}

export function Button({
  children,
  onClick,
  tone = 'default',
  disabled,
  className = '',
  type = 'button',
  title,
}: {
  children: ReactNode;
  onClick?: () => void;
  tone?: 'default' | 'primary' | 'danger' | 'ok' | 'ghost';
  disabled?: boolean;
  className?: string;
  type?: 'button' | 'submit';
  title?: string;
}) {
  const styles = {
    default: 'border-line-strong bg-bg-3 text-ink hover:border-accent/60',
    primary: 'border-accent bg-accent text-white hover:brightness-110',
    danger: 'border-danger/70 bg-danger-soft text-[#ffb3b8] hover:border-danger',
    ok: 'border-ok/70 bg-ok-soft text-ok hover:border-ok',
    ghost: 'border-transparent bg-transparent text-ink-2 hover:text-ink',
  }[tone];
  return (
    <button
      type={type}
      title={title}
      disabled={disabled}
      onClick={onClick}
      className={`inline-flex min-h-[40px] items-center justify-center gap-2 rounded-xl border px-4 text-sm font-medium transition ${styles} disabled:cursor-not-allowed disabled:opacity-40 ${className}`}
    >
      {children}
    </button>
  );
}
