// Auswahl von Fahrprofil und Antriebsmodus – gemeinsam genutzt von Fahransicht, Übersicht und Fahrmodi-Seite.

import { Check, Gauge, Leaf, Lock, SlidersHorizontal, Zap } from 'lucide-react';
import type { ComponentType } from 'react';
import { useIsOwner } from '../../hooks/common';
import { DRIVE_MODE_DESCRIPTION, DRIVE_MODE_LABEL, PROFILE_DESCRIPTION, PROFILE_LABEL } from '../../lib/labels';
import { command } from '../../services/wsClient';
import { useVehicle } from '../../stores/vehicleStore';
import type { DriveModeName, ProfileName } from '../../types/protocol';
import { AxleIcon } from '../common/Icons';

export const PROFILE_ICON: Record<ProfileName, ComponentType<{ className?: string }>> = {
  eco: Leaf,
  normal: Gauge,
  sport: Zap,
  custom: SlidersHorizontal,
};

export function axleIconProps(mode: DriveModeName): { front: boolean; rear: boolean } {
  return { front: mode !== 'rwd', rear: mode !== 'fwd' };
}

export function DriveModeList({ onDone, compact = false }: { onDone?: () => void; compact?: boolean }) {
  const current = useVehicle((s) => s.telemetry?.vehicle.drive_mode);
  const caps = useVehicle((s) => s.capabilities);
  const owner = useIsOwner();
  const modes: DriveModeName[] = ['awd', 'fwd', 'rwd', 'custom'];
  return (
    <div className={`flex flex-col ${compact ? 'gap-2' : 'gap-2.5'}`} role="radiogroup" aria-label="Antriebsmodus">
      {modes.map((mode) => {
        const availability = caps?.drive_modes[mode];
        const available = availability?.available ?? false;
        const selected = current === mode;
        return (
          <button
            key={mode}
            type="button"
            role="radio"
            aria-checked={selected}
            disabled={!owner || !available}
            title={!available ? (availability?.reason ?? 'Nicht verfügbar') : undefined}
            onClick={async () => {
              if (await command('set_drive_mode', { mode })) onDone?.();
            }}
            className={`flex items-center gap-4 rounded-xl border px-4 text-left transition ${compact ? 'py-2' : 'py-3'} ${
              selected ? 'border-accent bg-gradient-to-r from-accent-deep/70 to-accent-soft/60 shadow-glow-accent' : 'border-line bg-bg-2 hover:border-line-strong'
            } disabled:cursor-not-allowed ${!available ? 'opacity-45' : ''}`}
          >
            <AxleIcon {...axleIconProps(mode)} className={selected ? 'text-ink' : 'text-ink-2'} size={compact ? 26 : 30} />
            <div className="min-w-0 flex-1">
              <div className="text-[17px] font-semibold text-ink">{DRIVE_MODE_LABEL[mode]}</div>
              {(!compact || !available) && (
                <div className="truncate text-xs text-ink-2">{available ? DRIVE_MODE_DESCRIPTION[mode] : (availability?.reason ?? 'Nicht verfügbar')}</div>
              )}
            </div>
            {!available ? (
              <Lock className="h-4 w-4 text-ink-3" />
            ) : selected ? (
              <span className="flex h-6 w-6 items-center justify-center rounded-full bg-accent text-white">
                <Check className="h-4 w-4" strokeWidth={3} />
              </span>
            ) : (
              <span className="h-6 w-6 rounded-full border-2 border-line-strong" />
            )}
          </button>
        );
      })}
    </div>
  );
}

export function ProfileTiles({ onDone, columns = 4 }: { onDone?: () => void; columns?: 2 | 4 }) {
  const current = useVehicle((s) => s.telemetry?.vehicle.profile);
  const owner = useIsOwner();
  const profiles: ProfileName[] = ['eco', 'normal', 'sport', 'custom'];
  return (
    <div className={`grid gap-2.5 ${columns === 4 ? 'grid-cols-4' : 'grid-cols-2'}`} role="radiogroup" aria-label="Fahrprofil">
      {profiles.map((p) => {
        const Icon = PROFILE_ICON[p];
        const selected = current === p;
        const eco = p === 'eco';
        return (
          <button
            key={p}
            type="button"
            role="radio"
            aria-checked={selected}
            disabled={!owner}
            onClick={async () => {
              if (await command('set_profile', { profile: p })) onDone?.();
            }}
            className={`relative flex flex-col items-center justify-center gap-1.5 rounded-xl border py-3.5 text-sm transition ${
              selected
                ? eco
                  ? 'border-ok bg-ok-soft/70 text-ink shadow-glow-ok'
                  : 'border-accent bg-accent-soft/60 text-ink shadow-glow-accent'
                : 'border-line bg-bg-2 text-ink-2 hover:border-line-strong'
            } disabled:cursor-not-allowed disabled:opacity-60`}
            title={PROFILE_DESCRIPTION[p]}
          >
            <Icon className={`h-7 w-7 ${selected ? (eco ? 'text-ok' : 'text-accent') : ''}`} />
            {PROFILE_LABEL[p]}
            {selected && (
              <span className={`absolute bottom-1.5 right-1.5 flex h-4 w-4 items-center justify-center rounded-full ${eco ? 'bg-ok-2' : 'bg-accent'}`}>
                <Check className="h-3 w-3 text-bg-0" strokeWidth={3.5} />
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}
