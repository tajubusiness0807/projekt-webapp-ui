// Totmann-Eingabekanäle.
//
// Jede Eingabe (Gas, Bremse, Lenkung) ist nur gültig, solange die erzeugende Bedienquelle sie
// regelmäßig erneuert („Lease“). Hält eine Taste, ein Touch oder der Neigungssensor still oder
// stürzt die Komponente ab, verfällt der Wert nach LEASE_MS automatisch auf 0. Ein Gasbefehl kann
// dadurch nie „hängen bleiben“ – unabhängig davon, ob ein Loslassen-Ereignis ankommt.

import type { InputSource } from '../types/protocol';

export const LEASE_MS = 250;

export type ChannelName = 'throttle' | 'brake' | 'steer';

interface Channel {
  value: number;
  refreshedAt: number;
  source: InputSource;
}

export interface DriverInputs {
  throttle: number;
  brake: number;
  steer: number;
  source: InputSource;
}

const RANGES: Record<ChannelName, [number, number]> = {
  throttle: [0, 1],
  brake: [0, 1],
  steer: [-1, 1],
};

function clamp(value: number, [min, max]: [number, number]): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(max, Math.max(min, value));
}

export class InputChannels {
  private channels: Record<ChannelName, Channel> = {
    throttle: { value: 0, refreshedAt: 0, source: 'none' },
    brake: { value: 0, refreshedAt: 0, source: 'none' },
    steer: { value: 0, refreshedAt: 0, source: 'none' },
  };

  constructor(private readonly leaseMs: number = LEASE_MS) {}

  set(name: ChannelName, value: number, source: InputSource, now: number): void {
    this.channels[name] = { value: clamp(value, RANGES[name]), refreshedAt: now, source };
  }

  /** Bestätigt, dass die Quelle den Wert weiterhin hält (z. B. Finger liegt still auf). */
  refresh(name: ChannelName, now: number): void {
    const channel = this.channels[name];
    if (channel.value !== 0) channel.refreshedAt = now;
  }

  release(name: ChannelName): void {
    this.channels[name] = { value: 0, refreshedAt: 0, source: 'none' };
  }

  releaseAll(): void {
    (Object.keys(this.channels) as ChannelName[]).forEach((name) => this.release(name));
  }

  /** Effektiver Wert unter Berücksichtigung der Lease. */
  value(name: ChannelName, now: number): number {
    const channel = this.channels[name];
    if (channel.value === 0) return 0;
    if (now - channel.refreshedAt > this.leaseMs) return 0;
    return channel.value;
  }

  /** Liefert widerspruchsfreie Eingaben: Bremse hat Vorrang vor Gas. */
  read(now: number): DriverInputs {
    const brake = this.value('brake', now);
    let throttle = this.value('throttle', now);
    if (brake > 0) throttle = 0;
    const steer = this.value('steer', now);
    const active = (['throttle', 'brake', 'steer'] as ChannelName[]).find((n) => this.value(n, now) !== 0);
    return { throttle, brake, steer, source: active ? this.channels[active].source : 'none' };
  }
}

/** Abbildung der Fingerposition im Gaspedal (0 = unten, 1 = oben) auf die Gasanforderung. */
export function pedalValue(relativeHeight: number, mode: 'proportional' | 'full'): number {
  if (mode === 'full') return 1;
  const MIN = 0.1;
  const PADDING = 0.06;
  const usable = (relativeHeight - PADDING) / (1 - 2 * PADDING);
  return Math.min(1, Math.max(MIN, usable));
}
