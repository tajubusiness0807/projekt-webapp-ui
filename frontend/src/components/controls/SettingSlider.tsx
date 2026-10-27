// Schieberegler mit lokalem Entwurf: Ziehen ist flüssig, gespeichert wird beim Loslassen.
// Der angezeigte Wert folgt danach immer dem vom Backend bestätigten Wert.

import { useEffect, useRef, useState, type ReactNode } from 'react';
import { RangeField } from '../common/ui';

export function SettingSlider({
  label,
  value,
  min,
  max,
  step = 1,
  unit,
  digits = 0,
  disabled,
  hint,
  icon,
  accent,
  onCommit,
}: {
  label: ReactNode;
  value: number;
  min: number;
  max: number;
  step?: number;
  unit?: string;
  digits?: number;
  disabled?: boolean;
  hint?: ReactNode;
  icon?: ReactNode;
  accent?: 'accent' | 'ok';
  onCommit: (value: number) => Promise<unknown> | void;
}) {
  const [draft, setDraft] = useState(value);
  const editing = useRef(false);
  const confirmed = useRef(value);
  confirmed.current = value;
  useEffect(() => {
    if (!editing.current) setDraft(value);
  }, [value]);
  const commit = async (v: number) => {
    editing.current = false;
    const rounded = Number(v.toFixed(Math.max(digits, step < 1 ? 2 : 0)));
    if (rounded === confirmed.current) return;
    await onCommit(rounded);
    // Immer den vom Backend bestätigten Wert anzeigen (bei Ablehnung springt der Regler zurück).
    setDraft(confirmed.current);
  };
  return (
    <RangeField
      label={label}
      value={draft}
      min={min}
      max={max}
      step={step}
      unit={unit}
      digits={digits}
      disabled={disabled}
      hint={hint}
      icon={icon}
      accent={accent}
      onChange={(v) => {
        editing.current = true;
        setDraft(v);
      }}
      onCommit={commit}
    />
  );
}
