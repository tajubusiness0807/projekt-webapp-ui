// Neigungssteuerung: Umrechnung der Beschleunigungssensor-Daten in eine Lenkanforderung.
//
// Verwendet wird der Schwerkraftvektor (DeviceMotionEvent.accelerationIncludingGravity) statt der
// Euler-Winkel aus DeviceOrientation, weil er in Hoch- und Querformat ohne Kardanprobleme
// funktioniert. Der Vektor wird in Bildschirmkoordinaten gedreht (screen.orientation.angle), daraus
// ergibt sich der „Lenkradwinkel“ in der Bildschirmebene (Rollen) und die Vor-/Zurück-Neigung (Nicken).

export interface TiltSettings {
  full_lock_angle_deg: number;
  max_steer_percent: number;
  deadzone_deg: number;
  smoothing: number;
  invert: boolean;
  pitch_function: 'off' | 'throttle';
  pitch_full_angle_deg: number;
  pitch_deadzone_deg: number;
}

export interface Angles {
  roll: number; // Grad, positiv = im Uhrzeigersinn gedreht (Lenkung rechts)
  pitch: number; // Grad, positiv = Oberkante vom Fahrer weg geneigt
  valid: boolean;
}

/** Mindestanteil der Schwerkraft in der Bildschirmebene, damit der Rollwinkel stabil ist. */
export const MIN_IN_PLANE = 3.0; // m/s²

const DEG = 180 / Math.PI;

export function toScreenFrame(gx: number, gy: number, angleDeg: number): { x: number; y: number } {
  const a = (angleDeg * Math.PI) / 180;
  const c = Math.cos(a);
  const s = Math.sin(a);
  return { x: gx * c - gy * s, y: gx * s + gy * c };
}

export function anglesFromGravity(
  gx: number | null | undefined,
  gy: number | null | undefined,
  gz: number | null | undefined,
  screenAngleDeg: number,
): Angles {
  if (![gx, gy, gz].every((v) => typeof v === 'number' && Number.isFinite(v))) {
    return { roll: 0, pitch: 0, valid: false };
  }
  const { x, y } = toScreenFrame(gx as number, gy as number, screenAngleDeg);
  const inPlane = Math.hypot(x, y);
  const total = Math.hypot(x, y, gz as number);
  if (total < 4 || total > 20) return { roll: 0, pitch: 0, valid: false }; // starke Bewegung/Störung
  const pitch = Math.atan2(gz as number, inPlane) * DEG;
  if (inPlane < MIN_IN_PLANE) return { roll: 0, pitch, valid: false }; // Gerät liegt zu flach
  const roll = Math.atan2(-x, y) * DEG;
  return { roll, pitch, valid: true };
}

/** Kürzeste Winkeldifferenz in Grad (−180…180). */
export function angleDelta(a: number, b: number): number {
  let d = a - b;
  while (d > 180) d -= 360;
  while (d < -180) d += 360;
  return d;
}

export function steerFromRoll(roll: number, neutralRoll: number, s: TiltSettings): number {
  let angle = angleDelta(roll, neutralRoll);
  if (s.invert) angle = -angle;
  const magnitude = Math.abs(angle);
  if (magnitude <= s.deadzone_deg) return 0;
  const span = Math.max(1, s.full_lock_angle_deg - s.deadzone_deg);
  const normalized = Math.min(1, (magnitude - s.deadzone_deg) / span);
  return Math.sign(angle) * normalized * (s.max_steer_percent / 100);
}

export function throttleFromPitch(pitch: number, neutralPitch: number, s: TiltSettings): number {
  if (s.pitch_function !== 'throttle') return 0;
  const forward = neutralPitch - pitch; // Oberkante nach vorne kippen = Gas
  if (forward <= s.pitch_deadzone_deg) return 0;
  const span = Math.max(1, s.pitch_full_angle_deg - s.pitch_deadzone_deg);
  return Math.min(1, (forward - s.pitch_deadzone_deg) / span);
}

/** Exponentielle Glättung; ``smoothing`` 0 = ungefiltert, 0,95 = sehr träge. */
export class LowPass {
  private current: number | null = null;

  constructor(public smoothing: number) {}

  update(value: number): number {
    if (this.current === null) {
      this.current = value;
    } else {
      const k = 1 - Math.min(0.95, Math.max(0, this.smoothing));
      this.current += (value - this.current) * k;
    }
    return this.current;
  }

  reset(): void {
    this.current = null;
  }
}
