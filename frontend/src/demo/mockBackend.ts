// Browser-Demo: bildet das Backend (REST + WebSocket) im Browser nach.
//
// Nur im Build-Modus „demo“ enthalten (`npm run build:demo`). Damit lässt sich die Oberfläche ohne
// Raspberry Pi ausprobieren, z. B. als veröffentlichte Seite. Fahrlogik, Fahrzeugphysik und
// Sicherheitszustände sind vereinfachte Portierungen aus `backend/app` – die echte Sicherheitslogik
// läuft ausschließlich im Python-Backend. Es gibt hier keinerlei Verbindung zu Motoren.

import fixtures from './fixtures.json';
import type {
  ActiveFault,
  Capabilities,
  DriveModeName,
  DriveProfileSettings,
  EffectiveProfile,
  EventEntry,
  Measurement,
  ProfileName,
  Role,
  Severity,
  VehicleSettings,
  VehicleStateName,
  WheelPair,
} from '../types/protocol';

export const DEMO_PIN = '1234';
export const DEMO_ADMIN_PASSWORD = 'admin1234';

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

// ------------------------------------------------------------------ Fahrzeugphysik (wie vehicle_model.py)
const P = {
  mass: 110, wheelD: 0.165, track: 0.62, fMax: 95, rpmPerVolt: 23.5, crr: 0.025, cda: 0.55, coupling: 18,
  brakeForce: 140, eff: 0.82, copper: 0.0025, idle: 7, capacityAh: 4.4, rInt: 0.18, ambient: 22,
};
const SOC_REL: [number, number][] = [[0, 0], [0.05, 0.12], [0.15, 0.3], [0.3, 0.45], [0.45, 0.55], [0.6, 0.65], [0.75, 0.78], [0.9, 0.9], [1, 1]];
const REL_PCT: [number, number][] = [[0, 0], [0.12, 0.05], [0.3, 0.15], [0.45, 0.3], [0.55, 0.45], [0.65, 0.6], [0.78, 0.75], [0.9, 0.9], [1, 1]];

function interp(table: [number, number][], x: number): number {
  for (let i = 1; i < table.length; i++) {
    const [x0, y0] = table[i - 1];
    const [x1, y1] = table[i];
    if (x <= x1) return y0 + ((clamp(x, x0, x1) - x0) / (x1 - x0)) * (y1 - y0);
  }
  return table[table.length - 1][1];
}

type Axle = 'front' | 'rear';
const AXLES: Axle[] = ['front', 'rear'];

class Physics {
  vL = 0;
  vR = 0;
  soc = 0.78;
  voltage = 0;
  cmd: Record<Axle, WheelPair> = { front: { left: 0, right: 0 }, rear: { left: 0, right: 0 } };
  brake: Record<Axle, number> = { front: 0, rear: 0 };
  power: Record<Axle, number> = { front: 0, rear: 0 };
  ctrlTemp: Record<Axle, number> = { front: P.ambient + 3, rear: P.ambient + 4 };
  motorTemp: Record<Axle, number> = { front: P.ambient + 1, rear: P.ambient + 1 };
  constructor(private settings: () => VehicleSettings) {
    this.voltage = this.ocv();
  }
  ocv(): number {
    const b = this.settings().battery;
    return (b.cell_empty_v + interp(SOC_REL, this.soc) * (b.cell_full_v - b.cell_empty_v)) * b.cells_series;
  }
  rpm(side: 'left' | 'right'): number {
    return ((side === 'left' ? this.vL : this.vR) / (Math.PI * P.wheelD)) * 60;
  }
  get speedKmh(): number {
    return ((this.vL + this.vR) / 2) * 3.6;
  }
  private force(c: number, rpm: number, rpmMax: number): number {
    if (Math.abs(c) < 1e-4) return 0;
    const dir = Math.sign(c);
    return c * P.fMax * clamp(1 - (rpm * dir) / rpmMax, 0, 1);
  }
  private elec(f: number, v: number): number {
    const mech = (f * v) / 2;
    const cu = P.copper * f * f;
    return mech >= 0 ? mech / P.eff + cu : mech * P.eff + cu;
  }
  step(dt: number): void {
    if (dt <= 0) return;
    dt = Math.min(dt, 0.2);
    const rpmMax = Math.max(1, P.rpmPerVolt * this.voltage);
    let fL = 0;
    let fR = 0;
    let brakeTotal = 0;
    let total = P.idle;
    const forces: Record<Axle, [number, number]> = { front: [0, 0], rear: [0, 0] };
    for (const a of AXLES) {
      const l = this.force(this.cmd[a].left, this.rpm('left'), rpmMax);
      const r = this.force(this.cmd[a].right, this.rpm('right'), rpmMax);
      forces[a] = [l, r];
      fL += l;
      fR += r;
      brakeTotal += this.brake[a] * P.brakeForce * 2;
      this.power[a] = this.elec(l, this.vL) + this.elec(r, this.vR);
      total += Math.max(this.power[a], -50);
    }
    const half = P.mass / 2;
    const v = (this.vL + this.vR) / 2;
    const resist = Math.abs(v) > 0.02 ? Math.sign(v) * (P.crr * P.mass * 9.81 + 0.5 * 1.2 * P.cda * v * v) : 0;
    const coupling = P.coupling * (this.vL - this.vR);
    const integrate = (vs: number, drive: number) => {
      const brake = brakeTotal > 0 && vs !== 0 ? Math.sign(vs) * (brakeTotal / 2) : 0;
      const nv = vs + ((drive - resist / 2 - brake) / half) * dt;
      return brakeTotal > 0 && vs !== 0 && Math.sign(nv) !== Math.sign(vs) ? 0 : nv;
    };
    let nL = integrate(this.vL, fL - coupling);
    let nR = integrate(this.vR, fR + coupling);
    const stat = (P.crr * P.mass * 9.81) / 2;
    if (Math.abs(this.vL) < 0.02 && Math.abs(fL) < stat && brakeTotal === 0 && Math.abs(this.vR) < 0.02) nL = 0;
    if (Math.abs(this.vR) < 0.02 && Math.abs(fR) < stat && brakeTotal === 0 && Math.abs(this.vL) < 0.02) nR = 0;
    if (brakeTotal > 0 && Math.abs(nL) < 0.03 && Math.abs(nR) < 0.03) nL = nR = 0;
    this.vL = nL;
    this.vR = nR;
    const current = total / Math.max(this.voltage, 1);
    this.soc = clamp(this.soc - (current * dt) / 3600 / P.capacityAh, 0, 1);
    this.voltage = Math.max(0, this.ocv() - current * P.rInt);
    for (const a of AXLES) {
      const [l, r] = forces[a];
      const loss = Math.abs(this.power[a]) * 0.06 + P.copper * (l * l + r * r);
      this.ctrlTemp[a] += ((loss * 0.5 - (this.ctrlTemp[a] - P.ambient) * 1.6) / 900) * dt;
      this.motorTemp[a] += ((loss * 0.8 - (this.motorTemp[a] - P.ambient) * 2.4) / 1600) * dt;
    }
  }
}

// ------------------------------------------------------------------ Grenzen und Fahrlogik (wie limits.py / drive_logic.py)
function effectiveProfile(p: DriveProfileSettings, s: VehicleSettings): EffectiveProfile & { raw: Record<string, number> } {
  const limited: Record<string, string> = {};
  let maxThrottle = p.max_throttle_percent;
  if (maxThrottle > s.safety.absolute_max_throttle_percent) {
    maxThrottle = s.safety.absolute_max_throttle_percent;
    limited.max_throttle_percent = 'Sicherheitsgrenze';
  }
  let ramp = p.accel_ramp_percent_per_s;
  if (ramp > s.safety.absolute_max_accel_ramp_percent_per_s) {
    ramp = s.safety.absolute_max_accel_ramp_percent_per_s;
    limited.accel_ramp_percent_per_s = 'Sicherheitsgrenze';
  }
  let maxSpeed = p.max_speed_kmh;
  if (maxSpeed > s.safety.absolute_max_speed_kmh) {
    maxSpeed = s.safety.absolute_max_speed_kmh;
    limited.max_speed_kmh = 'Sicherheitsgrenze';
  }
  return {
    max_throttle_percent: maxThrottle,
    accel_ramp_percent_per_s: ramp,
    brake_strength_percent: p.brake_strength_percent,
    steering_sensitivity_percent: p.steering_sensitivity_percent,
    deadzone_percent: p.deadzone_percent,
    max_speed_kmh: maxSpeed,
    limited,
    raw: {
      front: p.front_power_limit_percent / 100,
      rear: p.rear_power_limit_percent / 100,
      left: p.left_limit_percent / 100,
      right: p.right_limit_percent / 100,
    },
  };
}

function deadzone(v: number, dz: number): number {
  const m = Math.abs(v);
  if (m <= dz) return 0;
  return Math.min(1, (m - dz) / (1 - dz)) * Math.sign(v);
}

function ramp(cur: number, target: number, step: number): number {
  if (target === 0) return 0;
  if (Math.sign(cur) !== Math.sign(target) && Math.abs(cur) > 1e-9) cur = 0;
  if (Math.abs(target) <= Math.abs(cur)) return target;
  return Math.sign(target) * Math.min(Math.abs(target), Math.abs(cur) + step);
}

// ------------------------------------------------------------------ Hilfen
function measurement(value: number | null, unit: string, status: Measurement['status'] = 'simulated', age = 20): Measurement {
  if (value === null || !Number.isFinite(value)) return { value: null, status: 'unavailable', age_ms: null, unit };
  return { value: Math.round(value * 100) / 100, status, age_ms: age, unit };
}

function deepMerge(base: Record<string, unknown>, patch: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(patch)) {
    out[k] = v && typeof v === 'object' && !Array.isArray(v) && out[k] && typeof out[k] === 'object' ? deepMerge(out[k] as Record<string, unknown>, v as Record<string, unknown>) : v;
  }
  return out;
}

const DRIVER_SECTIONS = new Set(['general', 'profiles', 'power_split', 'tilt', 'ui']);
const ADMIN_SECTIONS = new Set(['battery', 'temperature', 'safety', 'hardware', 'telemetry']);

function validatePatch(patch: Record<string, unknown>, admin: boolean): string | null {
  for (const [section, fields] of Object.entries(patch)) {
    if (DRIVER_SECTIONS.has(section)) continue;
    if (ADMIN_SECTIONS.has(section)) {
      const onlyProtection = section === 'battery' && fields && typeof fields === 'object' && Object.keys(fields).every((k) => k === 'protection_enabled');
      if (!admin && !onlyProtection) return `Für den Abschnitt „${section}“ sind Administratorrechte nötig`;
      continue;
    }
    return `Unbekannter Abschnitt „${section}“`;
  }
  const flat = JSON.stringify(patch);
  if (/null|NaN|Infinity/.test(flat)) return 'Einstellungen ungültig';
  const split = (patch.power_split as { awd_front_percent?: number } | undefined)?.awd_front_percent;
  if (split !== undefined && (split < 20 || split > 80)) return 'Einstellungen ungültig – power_split.awd_front_percent: 20 … 80';
  return null;
}

// ------------------------------------------------------------------ Demo-Server
const FAULT_DEFS = new Map(fixtures.fault_catalog.map((d) => [d.code, d]));

interface Fault {
  code: string;
  source: string;
  detail: string;
  since: number;
  active: boolean;
  count: number;
}

class DemoSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  readyState = 0;
  onopen: ((ev: Event) => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: ((ev: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;
  session: Session | null = null;
  lastSeq = 0;

  constructor(_url: string) {
    window.setTimeout(() => {
      this.readyState = 1;
      this.onopen?.(new Event('open'));
    }, 40);
  }

  send(data: string): void {
    if (this.readyState !== 1) throw new Error('Socket nicht offen');
    server.receive(this, data);
  }

  close(code = 1000, reason = ''): void {
    if (this.readyState >= 2) return;
    this.readyState = 3;
    server.disconnect(this);
    window.setTimeout(() => this.onclose?.({ code, reason, wasClean: true }), 0);
  }

  deliver(message: unknown): void {
    if (this.readyState !== 1) return;
    const data = JSON.stringify(message);
    window.setTimeout(() => this.onmessage?.({ data }), 0);
  }
}

interface Session {
  id: string;
  role: Role;
  device: string;
  clientId: string;
}

class DemoServer {
  settings: VehicleSettings = clone(fixtures.settings) as VehicleSettings;
  version = 1;
  history = [{ version: 1, created_at: Date.now(), source: 'standardwerte' }];
  profile: ProfileName = this.settings.general.default_profile;
  driveMode: DriveModeName = this.settings.general.default_drive_mode;
  direction: 'forward' | 'reverse' = 'forward';
  state: VehicleStateName = 'locked';
  estop = false;
  neutralRequired = true;
  faults = new Map<string, Fault>();
  sockets = new Set<DemoSocket>();
  owner: DemoSocket | null = null;
  lastOwnerClient: string | null = null;
  input = { throttle: 0, brake: 0, steer: 0, at: 0 };
  lastMessageAt = 0;
  wheels: Record<Axle, WheelPair> = { front: { left: 0, right: 0 }, rear: { left: 0, right: 0 } };
  output = { target: 0, effective: 0, brake: 0, steer: 0, limit: 0, factor: 1, limitedBy: [] as string[] };
  brakeState: 'inactive' | 'coasting' | 'requested' | 'confirmed' = 'inactive';
  speedHistory: [number, number][] = [];
  physics = new Physics(() => this.settings);
  simFaults = new Set<string>();
  trip = 0;
  total = 12.6 * 3600;
  events: EventEntry[] = [];
  eventId = 1;
  telemetrySeq = 0;
  lastStep = performance.now();
  started = performance.now();
  lowSince: number | null = null;
  warnSince: number | null = null;
  errorFrames = 0;
  ownerTimeoutReported = false;

  constructor() {
    this.record('info', 'START', 'system', 'AllWheel Control (Browser-Demo) gestartet');
    this.record('info', 'MODE', 'system', 'Betriebsart: SIMULATION – keine realen Motorbefehle');
    window.setInterval(() => this.step(), 40);
    window.setInterval(() => this.broadcast(), 100);
  }

  // ---------------------------------------------------------------- Ereignisse und Fehler
  record(level: Severity, code: string, category: string, message: string, details: Record<string, unknown> | null = null): void {
    const event: EventEntry = { id: this.eventId++, ts: Date.now(), level, code, category, message, details };
    this.events.unshift(event);
    this.events = this.events.slice(0, 300);
    for (const s of this.sockets) s.deliver({ type: 'event', event });
  }

  condition(code: string, source: string, active: boolean, detail = ''): void {
    const key = `${code}:${source}`;
    const fault = this.faults.get(key);
    const def = FAULT_DEFS.get(code);
    if (!def) return;
    if (active) {
      if (!fault) {
        this.faults.set(key, { code, source, detail, since: Date.now(), active: true, count: 1 });
        this.record(def.severity as Severity, code, 'fehler', def.title, { quelle: source, detail });
      } else if (!fault.active) {
        fault.active = true;
        fault.count += 1;
        fault.detail = detail || fault.detail;
      } else if (detail) fault.detail = detail;
    } else if (fault && fault.active) {
      fault.active = false;
      if (!def.blocking) this.faults.delete(key);
    }
    this.recompute();
  }

  raise(code: string, source: string, detail = ''): void {
    const key = `${code}:${source}`;
    const def = FAULT_DEFS.get(code)!;
    const fault = this.faults.get(key);
    if (fault) fault.count += 1;
    else this.faults.set(key, { code, source, detail, since: Date.now(), active: false, count: 1 });
    this.record(def.severity as Severity, code, 'fehler', def.title, { quelle: source, detail });
    this.recompute();
  }

  blocking(): Fault[] {
    return [...this.faults.values()].filter((f) => FAULT_DEFS.get(f.code)?.blocking);
  }

  recompute(): void {
    let target: VehicleStateName = this.state;
    if (this.estop) target = 'emergency_stop';
    else if (this.blocking().length) target = 'fault';
    else if (this.state === 'fault' || this.state === 'emergency_stop') target = 'locked';
    this.setState(target, 'Zustandsprüfung');
  }

  setState(next: VehicleStateName, reason: string): void {
    if (next === this.state) return;
    const old = this.state;
    this.state = next;
    if (next !== 'armed') {
      this.neutralRequired = true;
      this.wheels = { front: { left: 0, right: 0 }, rear: { left: 0, right: 0 } };
      this.input = { throttle: 0, brake: 0, steer: 0, at: this.input.at };
    }
    this.record(next === 'fault' || next === 'emergency_stop' ? 'warning' : 'info', 'STATE', 'sicherheit', `Zustand ${old} → ${next}`, { grund: reason });
    this.broadcast();
  }

  // ---------------------------------------------------------------- Regelschleife
  step(): void {
    const now = performance.now();
    const dt = (now - this.lastStep) / 1000;
    this.lastStep = now;
    const s = this.settings;
    const frontOff = this.simFaults.has('front_offline');
    const rearOff = this.simFaults.has('rear_offline');
    const offline = [frontOff && 'Controller A (vorne)', rearOff && 'Controller B (hinten)'].filter(Boolean) as string[];
    this.condition('E001', 'antrieb', offline.length === 2, offline.join('; '));
    this.condition('E002', 'antrieb', offline.length === 1, offline.join('; '));
    this.condition('E004', 'controller_front', this.simFaults.has('front_invalid_data'), 'Drehzahl links unplausibel (32000 U/min)');
    if (this.simFaults.has('rear_comm_errors')) this.errorFrames += 2;
    this.condition('E003', 'controller_rear', this.simFaults.has('rear_comm_errors'), 'Controller B (hinten): fehlerhafte Pakete');

    // Akku und Temperatur
    const v = this.voltage();
    const crit = s.battery.cell_critical_v * s.battery.cells_series;
    const warn = s.battery.cell_warning_v * s.battery.cells_series;
    if (v < crit) {
      this.lowSince ??= now;
      if (now - this.lowSince > 2000) this.condition('E006', 'akku', true, `${v.toFixed(1)} V < ${crit.toFixed(1)} V`);
    } else {
      this.lowSince = null;
      if (v > crit + 0.3) this.condition('E006', 'akku', false);
    }
    if (v < warn) {
      this.warnSince ??= now;
      if (now - this.warnSince > 2000) this.condition('W006', 'akku', true, `${v.toFixed(1)} V < ${warn.toFixed(1)} V`);
    } else {
      this.warnSince = null;
      if (v > warn + 0.3) this.condition('W006', 'akku', false);
    }
    const temp = this.controllerTemp();
    this.condition('E005', 'temperatur', temp >= s.temperature.controller_critical_c, `Controller ${temp.toFixed(0)} °C`);
    this.condition('W005', 'temperatur', temp >= s.temperature.controller_warning_c, `Controller ${temp.toFixed(0)} °C`);

    // Steuergerät stumm?
    if (this.owner && this.state === 'armed' && now - this.lastMessageAt > s.safety.connection_timeout_ms) {
      if (!this.ownerTimeoutReported) {
        this.ownerTimeoutReported = true;
        this.raise('E007', 'steuergeraet', 'Keine Nachricht mehr vom steuernden Gerät');
        this.setState('locked', 'Verbindung verloren');
        this.recompute();
      }
    }

    // Fahreranforderung (Totmann, Neutralverriegelung)
    let inp = { throttle: 0, brake: 0, steer: 0 };
    if (this.state === 'armed') {
      const age = now - this.input.at;
      if (age > s.safety.command_timeout_ms) {
        if (!this.neutralRequired) {
          this.neutralRequired = true;
          this.condition('W012', 'fahranforderung', true, `Letzter Befehl vor ${age.toFixed(0)} ms`);
        }
      } else {
        inp = { throttle: this.input.throttle, brake: this.input.brake, steer: this.input.steer };
        if (this.neutralRequired) {
          if (inp.throttle === 0) {
            this.neutralRequired = false;
            this.condition('W012', 'fahranforderung', false);
          } else inp.throttle = 0;
        }
      }
    } else this.condition('W012', 'fahranforderung', false);

    // Fahrlogik
    const prof = effectiveProfile(s.profiles[this.profile], s);
    const [wf, wr] = this.weights();
    const big = Math.max(wf, wr) || 1;
    const scale = { front: wf / big, rear: wr / big };
    const speed = this.speed();
    const out = { target: 0, effective: 0, brake: 0, steer: 0, limit: prof.max_speed_kmh, factor: 1, limitedBy: [] as string[] };
    if (this.state === 'armed') {
      let t = deadzone(clamp(inp.throttle, 0, 1), prof.deadzone_percent / 100);
      const st = deadzone(clamp(inp.steer, -1, 1), prof.deadzone_percent / 100);
      const b = clamp(inp.brake, 0, 1);
      if (b > 0) t = 0;
      out.target = t;
      let maxT = prof.max_throttle_percent / 100;
      const reverse = this.direction === 'reverse';
      if (reverse) {
        maxT = Math.min(maxT, s.safety.reverse_max_throttle_percent / 100);
        out.limit = Math.min(out.limit, s.safety.reverse_max_speed_kmh);
        if (t > 0) out.limitedBy.push('rueckwaerts');
      }
      let eff = t * maxT;
      if (t > 0 && maxT < 1) out.limitedBy.push('profil');
      if (s.battery.protection_enabled && v < warn && eff > 0) {
        eff *= 0.5 + 0.5 * clamp((v - crit) / Math.max(0.1, warn - crit), 0, 1);
        out.limitedBy.push('akku');
      }
      if (temp >= s.temperature.controller_warning_c && eff > 0) {
        eff *= 1 - 0.5 * clamp((temp - s.temperature.controller_warning_c) / 15, 0, 1);
        out.limitedBy.push('temperatur');
      }
      const band = Math.max(1, 0.15 * out.limit);
      out.factor = clamp((out.limit - Math.abs(speed)) / band, 0, 1);
      if (out.factor < 1 && eff > 0) out.limitedBy.push('geschwindigkeit');
      eff *= out.factor;
      out.effective = eff;
      const base = reverse ? -eff : eff;
      const diff = clamp(st * (prof.steering_sensitivity_percent / 100), -1, 1);
      out.steer = diff;
      const inner = base * (1 - Math.abs(diff));
      const [left, right] = diff >= 0 ? [base, inner] : [inner, base];
      const stepSize = (prof.accel_ramp_percent_per_s / 100) * dt;
      for (const a of AXLES) {
        const limitAxle = a === 'front' ? prof.raw.front : prof.raw.rear;
        const target = {
          left: clamp(left * scale[a] * limitAxle * prof.raw.left, -1, 1),
          right: clamp(right * scale[a] * limitAxle * prof.raw.right, -1, 1),
        };
        if (b > 0) this.wheels[a] = { left: 0, right: 0 };
        else this.wheels[a] = { left: ramp(this.wheels[a].left, target.left, stepSize), right: ramp(this.wheels[a].right, target.right, stepSize) };
        this.physics.cmd[a] = { ...this.wheels[a] };
        this.physics.brake[a] = b > 0 ? b * (prof.brake_strength_percent / 100) : 0;
      }
      out.brake = b > 0 ? b * (prof.brake_strength_percent / 100) : 0;
    } else {
      // Gesperrt: Antrieb aus, simulierte (verifizierte) Bremse bei Bewegung
      const moving = Math.abs(speed) > s.safety.standstill_speed_kmh;
      for (const a of AXLES) {
        this.wheels[a] = { left: 0, right: 0 };
        this.physics.cmd[a] = { left: 0, right: 0 };
        this.physics.brake[a] = moving ? 0.7 : 0;
      }
    }
    this.output = out;
    this.physics.step(dt);

    // Bremszustand aus gemessener Verzögerung
    this.speedHistory.push([now, Math.abs(this.physics.speedKmh)]);
    this.speedHistory = this.speedHistory.filter(([t]) => now - t < 400);
    const moving = Math.abs(this.physics.speedKmh) > s.safety.standstill_speed_kmh;
    if (this.state !== 'armed') this.brakeState = 'inactive';
    else if (inp.brake > 0) {
      const [first, last] = [this.speedHistory[0], this.speedHistory[this.speedHistory.length - 1]];
      const decel = first && last && last[0] - first[0] > 100 ? (first[1] - last[1]) / ((last[0] - first[0]) / 1000) : 0;
      this.brakeState = !moving || decel >= 1 ? 'confirmed' : 'requested';
    } else this.brakeState = out.target <= 0 && moving ? 'coasting' : 'inactive';

    if (this.state === 'armed') {
      this.trip += dt;
      this.total += dt;
    }
  }

  weights(): [number, number] {
    if (this.driveMode === 'fwd') return [100, 0];
    if (this.driveMode === 'rwd') return [0, 100];
    const front = this.driveMode === 'custom' ? this.settings.power_split.custom_front_percent : this.settings.power_split.awd_front_percent;
    return [front, 100 - front];
  }

  voltage(): number {
    const b = this.settings.battery;
    if (this.simFaults.has('battery_critical')) return b.cell_critical_v * b.cells_series - 0.6;
    if (this.simFaults.has('battery_warning')) return b.cell_warning_v * b.cells_series - 0.4;
    return this.physics.voltage;
  }

  controllerTemp(): number {
    if (this.simFaults.has('overtemperature')) return this.settings.temperature.controller_critical_c + 6;
    return Math.max(this.physics.ctrlTemp.front, this.physics.ctrlTemp.rear);
  }

  speed(): number {
    return this.physics.speedKmh;
  }

  isStanding(): boolean {
    return Math.abs(this.speed()) <= this.settings.safety.standstill_speed_kmh;
  }

  // ---------------------------------------------------------------- Nachrichten
  receive(socket: DemoSocket, raw: string): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(raw);
    } catch {
      socket.deliver({ type: 'ack', ref_type: 'unbekannt', ref_seq: null, ok: false, code: 'INVALID_MESSAGE', message: 'Ungültiges JSON' });
      return;
    }
    const type = String(msg.type);
    if (type === 'hello') return this.hello(socket, msg);
    if (!socket.session) return;
    if (socket === this.owner) this.lastMessageAt = performance.now();
    if (type === 'ping') {
      socket.deliver({ type: 'pong', ts: msg.ts, server_ts: Date.now() });
      return;
    }
    const seq = Number(msg.seq);
    const ack = (ok = true, code?: string, message?: string, extra: Record<string, unknown> = {}) =>
      socket.deliver({ type: 'ack', ref_type: type, ref_seq: seq, ok, ...(code ? { code } : {}), ...(message ? { message } : {}), ...extra });
    if (!(seq > socket.lastSeq)) return ack(false, 'SEQ_ORDER', 'Sequenznummer nicht steigend');
    socket.lastSeq = seq;
    const isOwner = socket === this.owner;
    const ownerOnly = !['estop', 'claim_control', 'release_control', 'takeover_control'].includes(type);
    if (ownerOnly && !isOwner) return ack(false, 'NOT_OWNER', 'Nur das steuernde Gerät darf diesen Befehl senden');

    switch (type) {
      case 'drive': {
        const throttle = Number(msg.throttle);
        const brake = Number(msg.brake);
        const steer = Number(msg.steer);
        if (![throttle, brake, steer].every(Number.isFinite) || throttle < 0 || throttle > 1 || brake < 0 || brake > 1 || Math.abs(steer) > 1)
          return ack(false, 'INVALID_MESSAGE', 'Wert außerhalb des Bereichs');
        if (throttle > 0 && brake > 0) {
          this.input = { throttle: 0, brake, steer, at: performance.now() };
          return ack(false, 'CONTRADICTORY', 'Gas und Bremse gleichzeitig – Gas verworfen');
        }
        if (msg.profile !== this.profile) return ack(false, 'PROFILE_MISMATCH', 'Profil stimmt nicht');
        this.input = { throttle, brake, steer, at: performance.now() };
        return;
      }
      case 'claim_control':
        if (this.owner && this.owner !== socket) return ack(false, 'CONTROL_BUSY', 'Die Steuerung ist bereits einem anderen Gerät zugeordnet');
        this.assignOwner(socket);
        this.record('info', 'CONTROL', 'verbindung', `Steuerung durch ${socket.session.device} übernommen`);
        ack();
        return this.broadcast();
      case 'takeover_control':
        if (this.state === 'armed' && !this.isStanding()) return ack(false, 'VEHICLE_MOVING', 'Übernahme nur im Stillstand möglich');
        if (this.state === 'armed') this.setState('locked', 'Steuerung übernommen');
        if (this.owner && this.owner !== socket) this.owner.deliver({ type: 'connection', event: 'control_lost', message: 'Die Steuerung wurde von einem anderen Gerät übernommen. Motoren gesperrt.' });
        this.assignOwner(socket);
        ack();
        return this.broadcast();
      case 'release_control':
        if (isOwner) {
          this.setState('locked', 'Steuerung abgegeben');
          this.owner = null;
          this.lastOwnerClient = null;
        }
        ack();
        return this.broadcast();
      case 'estop':
        this.estop = true;
        this.input = { throttle: 0, brake: 0, steer: 0, at: 0 };
        if (!this.faults.has('E010:system')) this.faults.set('E010:system', { code: 'E010', source: 'system', detail: `Ausgelöst durch ${socket.session.device}`, since: Date.now(), active: true, count: 1 });
        this.record('critical', 'E010', 'sicherheit', 'Not-Aus ausgelöst', { quelle: socket.session.device });
        this.recompute();
        return ack();
      case 'estop_reset':
        if (this.input.throttle > 0) return ack(false, 'NOT_NEUTRAL', 'Gas muss losgelassen sein');
        if (!this.estop) return ack(false, 'NOT_ACTIVE', 'Not-Aus ist nicht aktiv');
        this.estop = false;
        this.faults.delete('E010:system');
        this.record('info', 'ESTOP_RESET', 'sicherheit', 'Not-Aus zurückgesetzt – Motoren bleiben gesperrt');
        this.recompute();
        return ack();
      case 'ack_faults': {
        let removed = 0;
        for (const [key, f] of this.faults) {
          if (!f.active && f.code !== 'E010') {
            this.faults.delete(key);
            removed++;
          }
        }
        this.recompute();
        const remaining = this.blocking();
        if (remaining.length) return ack(false, 'FAULTS_ACTIVE', `Noch aktiv: ${remaining.map((f) => `${f.code} ${FAULT_DEFS.get(f.code)?.title}`).join(', ')}`);
        return ack(true, undefined, `${removed} Fehler quittiert`);
      }
      case 'arm': {
        const failed: string[] = [];
        if (this.estop) return ack(false, 'ARM_REFUSED', 'Not-Aus ist aktiv');
        if (this.state !== 'locked') return ack(false, 'ARM_REFUSED', 'Kritische Fehler müssen zuerst behoben und quittiert werden');
        if (this.input.throttle > 0) failed.push('Gas muss losgelassen sein');
        if (!this.isStanding()) failed.push('Fahrzeug muss stehen');
        if (this.simFaults.has('front_offline') || this.simFaults.has('rear_offline')) failed.push('Controller ohne aktuelle Rückmeldung');
        if (failed.length) return ack(false, 'ARM_REFUSED', failed.join('; '));
        this.neutralRequired = false;
        this.ownerTimeoutReported = false;
        this.lastMessageAt = performance.now();
        this.setState('armed', 'Motorfreigabe durch Fahrer');
        return ack();
      }
      case 'disarm':
        this.setState('locked', 'Motoren durch Fahrer gesperrt');
        return ack();
      case 'set_profile':
        this.profile = msg.profile as ProfileName;
        this.record('info', 'PROFILE', 'fahrmodus', `Fahrprofil: ${this.profile}`);
        ack();
        return this.broadcast();
      case 'set_drive_mode':
        this.driveMode = msg.mode as DriveModeName;
        this.record('info', 'DRIVE_MODE', 'antrieb', `Antriebsmodus: ${this.driveMode}`);
        ack();
        return this.broadcast();
      case 'set_direction':
        if (!this.isStanding() || this.input.throttle > 0) return ack(false, 'NOT_STANDING', 'Fahrtrichtung nur im Stillstand und ohne Gas umschaltbar');
        this.direction = msg.direction as 'forward' | 'reverse';
        ack();
        return this.broadcast();
      case 'set_power_split': {
        const key = msg.target === 'awd' ? 'awd_front_percent' : 'custom_front_percent';
        return this.savePatch(socket, ack, { power_split: { [key]: Math.round(Number(msg.front_percent) * 10) / 10 } });
      }
      case 'update_settings':
        return this.savePatch(socket, ack, msg.patch as Record<string, unknown>);
      case 'reset_profiles':
        return this.savePatch(socket, ack, { profiles: clone(fixtures.settings.profiles) });
      case 'reset_trip':
        this.trip = 0;
        return ack();
      case 'sim_inject': {
        const fault = String(msg.fault);
        if (!(fault in fixtures.simulation_faults)) return ack(false, 'UNKNOWN_FAULT', 'Unbekannter Simulationsfehler');
        if (msg.active) this.simFaults.add(fault);
        else this.simFaults.delete(fault);
        this.record('warning', 'SIM_FAULT', 'simulation', `Simulationsfehler ${msg.active ? 'aktiviert' : 'deaktiviert'}: ${(fixtures.simulation_faults as Record<string, string>)[fault]}`);
        ack();
        return this.broadcast();
      }
      default:
        return ack(false, 'UNKNOWN', 'Unbekannter Nachrichtentyp');
    }
  }

  assignOwner(socket: DemoSocket): void {
    this.owner = socket;
    this.lastOwnerClient = socket.session?.clientId ?? null;
    this.input = { throttle: 0, brake: 0, steer: 0, at: 0 };
    this.lastMessageAt = performance.now();
  }

  savePatch(socket: DemoSocket, ack: (ok?: boolean, code?: string, message?: string, extra?: Record<string, unknown>) => void, patch: Record<string, unknown>): void {
    const problem = validatePatch(patch, socket.session?.role === 'admin');
    if (problem) return ack(false, 'INVALID_SETTINGS', problem);
    this.applySettings(deepMerge(this.settings as unknown as Record<string, unknown>, patch) as unknown as VehicleSettings, `websocket:${socket.session?.device}`);
    ack(true, undefined, undefined, { version: this.version });
  }

  applySettings(next: VehicleSettings, source: string): void {
    this.settings = next;
    this.version += 1;
    this.history.unshift({ version: this.version, created_at: Date.now(), source });
    this.record('info', 'CONFIG', 'konfiguration', `Einstellungen gespeichert (Version ${this.version})`, { quelle: source });
    for (const s of this.sockets) s.deliver({ type: 'settings', version: this.version, settings: this.settings, capabilities: this.capabilities() });
  }

  hello(socket: DemoSocket, msg: Record<string, unknown>): void {
    const role = tokenRole(String(msg.token ?? ''));
    if (!role) {
      socket.deliver({ type: 'error', code: 'AUTH', message: 'Anmeldung ungültig oder abgelaufen' });
      socket.close(4001, 'Anmeldung ungültig');
      return;
    }
    const clientId = String(msg.client_id ?? 'demo');
    socket.session = { id: Math.random().toString(16).slice(2, 10), role, device: String(msg.device ?? 'Browser'), clientId };
    this.sockets.add(socket);
    if (!this.owner && this.lastOwnerClient === clientId) this.assignOwner(socket);
    socket.deliver({
      type: 'welcome',
      protocol: 1,
      version: '1.0.0 (Demo)',
      session_id: socket.session.id,
      role,
      mode: 'simulation',
      server_time: Date.now(),
      settings: this.settings,
      settings_version: this.version,
      capabilities: this.capabilities(),
      fault_catalog: fixtures.fault_catalog,
      events: this.events.slice(0, 50),
    });
    this.broadcast();
  }

  disconnect(socket: DemoSocket): void {
    this.sockets.delete(socket);
    if (socket === this.owner) {
      this.owner = null;
      if (this.state === 'armed') {
        this.raise('E007', 'steuergeraet', 'Verbindung des steuernden Geräts getrennt');
        this.setState('locked', 'Steuernde Verbindung getrennt');
        this.recompute();
      }
    }
  }

  capabilities(): Capabilities {
    const b = this.settings.battery;
    const available = { available: true, reason: null };
    return {
      mode: 'simulation',
      drive_modes: { awd: available, fwd: available, rwd: available, custom: available },
      axle_distribution: available,
      brake: { available: true, method: 'simulated', note: 'Simulierte Bremse (Browser-Demo)' },
      measurements: { speed: true, voltage: true, controller_temperature: true, motor_temperature: true, electrical_power: true },
      commissioning: false,
      hardware_init_error: null,
      readiness: fixtures.readiness,
      restart_required: false,
      simulation_faults: fixtures.simulation_faults,
      battery_limits: {
        full_v: b.cell_full_v * b.cells_series,
        warning_v: b.cell_warning_v * b.cells_series,
        critical_v: b.cell_critical_v * b.cells_series,
        empty_v: b.cell_empty_v * b.cells_series,
      },
      effective_profiles: Object.fromEntries(
        (['eco', 'normal', 'sport', 'custom'] as ProfileName[]).map((p) => {
          const { raw: _raw, ...eff } = effectiveProfile(this.settings.profiles[p], this.settings);
          return [p, eff];
        }),
      ) as Record<ProfileName, EffectiveProfile>,
      wheel_diameter_m: P.wheelD,
    };
  }

  // ---------------------------------------------------------------- Telemetrie
  broadcast(): void {
    if (!this.sockets.size) return;
    const base = this.snapshot();
    for (const s of this.sockets) {
      const isOwner = s === this.owner;
      s.deliver({
        ...base,
        session: {
          id: s.session?.id ?? '',
          role: s.session?.role ?? 'driver',
          is_owner: isOwner,
          owner_present: !!this.owner,
          owner_device: this.owner?.session?.device ?? null,
          count: this.sockets.size,
          can_takeover: !isOwner && (this.state !== 'armed' || this.isStanding()),
        },
      });
    }
  }

  snapshot() {
    const p = this.physics;
    const frontOff = this.simFaults.has('front_offline');
    const rearOff = this.simFaults.has('rear_offline');
    const bothOff = frontOff && rearOff;
    const stale = (m: Measurement): Measurement => (bothOff && m.value !== null ? { ...m, status: 'stale', age_ms: 1500 } : m);
    const voltage = this.voltage();
    const b = this.settings.battery;
    const rel = (voltage / b.cells_series - b.cell_empty_v) / (b.cell_full_v - b.cell_empty_v);
    const percent = clamp(interp(REL_PCT, clamp(rel, 0, 1)) * 100, 0, 100);
    const rpmL = p.rpm('left');
    const rpmR = p.rpm('right');
    const [wf, wr] = this.weights();
    const big = Math.max(wf, wr) || 1;
    const wifi = this.simFaults.has('wifi_weak') ? -82 + Math.random() * 4 : -48 + Math.random() * 4;
    const prof = effectiveProfile(this.settings.profiles[this.profile], this.settings);
    const { raw: _raw, ...effective } = prof;
    const faults: ActiveFault[] = [...this.faults.values()]
      .map((f) => {
        const def = FAULT_DEFS.get(f.code)!;
        return { ...f, blocking: def.blocking, severity: def.severity as Severity, title: def.title };
      })
      .sort((a, b2) => ['critical', 'warning', 'info'].indexOf(a.severity) - ['critical', 'warning', 'info'].indexOf(b2.severity));
    const controller = (id: 'A' | 'B', axle: Axle, off: boolean) => ({
      id,
      axle,
      adapter: 'simulation',
      link: off ? 'error' : 'connected',
      feedback_age_ms: off ? 1500 : 12,
      frames_ok: Math.floor((performance.now() - this.started) / 40),
      frames_bad: axle === 'rear' ? this.errorFrames : 0,
      commands_sent: Math.floor((performance.now() - this.started) / 40),
      write_errors: 0,
      last_error: off ? 'Keine Rückmeldung (simuliert)' : null,
      emergency_stopped: this.estop,
      port: 'simulation',
      capabilities: { simulated: true },
      rpm_left: off ? { ...measurement(rpmL, 'U/min'), status: 'stale' as const } : measurement(axle === 'front' && this.simFaults.has('front_invalid_data') ? null : rpmL, 'U/min'),
      rpm_right: off ? { ...measurement(rpmR, 'U/min'), status: 'stale' as const } : measurement(rpmR, 'U/min'),
      voltage: measurement(voltage, 'V', off ? 'stale' : 'simulated'),
      controller_temp_c: measurement(this.simFaults.has('overtemperature') ? this.controllerTemp() : p.ctrlTemp[axle], '°C', off ? 'stale' : 'simulated'),
      motor_temp_c: measurement(p.motorTemp[axle], '°C', off ? 'stale' : 'simulated'),
      electrical_power_w: measurement(p.power[axle], 'W', off ? 'stale' : 'simulated'),
    });
    this.telemetrySeq += 1;
    return {
      type: 'telemetry',
      seq: this.telemetrySeq,
      ts: Date.now(),
      mode: 'simulation',
      vehicle: {
        state: this.state,
        armed: this.state === 'armed',
        neutral_required: this.neutralRequired,
        estop: this.estop,
        direction: this.direction,
        profile: this.profile,
        drive_mode: this.driveMode,
        brake_state: this.brakeState,
        brake_support: this.brakeState === 'requested' || this.brakeState === 'confirmed' ? 'applied' : null,
        trip_s: Math.floor(this.trip),
        total_drive_s: Math.floor(this.total),
        restart_required: false,
        commissioning: false,
        sim_faults: [...this.simFaults],
      },
      measurements: {
        speed_kmh: stale(measurement(Math.abs(p.speedKmh), 'km/h')),
        motor_rpm: stale(measurement((Math.abs(rpmL) + Math.abs(rpmR)) / 2, 'U/min')),
        battery_voltage: stale(measurement(voltage + (Math.random() - 0.5) * 0.04, 'V')),
        battery_percent: stale(measurement(Math.round(percent), '%')),
        controller_temp_c: stale(measurement(this.controllerTemp(), '°C')),
        motor_temp_c: stale(measurement(Math.max(p.motorTemp.front, p.motorTemp.rear), '°C')),
        electrical_power_w: stale(measurement(p.power.front + p.power.rear, 'W')),
        wifi_signal_dbm: measurement(Math.round(wifi), 'dBm', 'simulated', 900),
        wifi_quality: wifi >= -55 ? 'stark' : wifi >= -67 ? 'gut' : wifi >= -75 ? 'mittel' : 'schwach',
      },
      control: {
        input: { throttle: this.input.throttle, brake: this.input.brake, steer: this.input.steer },
        output: {
          target_throttle: this.output.target,
          effective_throttle: this.output.effective,
          drive_level: Math.max(...AXLES.flatMap((a) => [Math.abs(this.wheels[a].left), Math.abs(this.wheels[a].right)])),
          brake_level: this.output.brake,
          steer: this.output.steer,
          speed_limit_kmh: this.output.limit,
          speed_factor: this.output.factor,
          front: { ...this.wheels.front },
          rear: { ...this.wheels.rear },
          limited_by: this.output.limitedBy,
        },
        split: { front_weight: wf, rear_weight: wr, front_scale: wf / big, rear_scale: wr / big, distribution_available: true },
        effective_profile: effective,
      },
      controllers: [controller('A', 'front', frontOff), controller('B', 'rear', rearOff)],
      faults,
      system: { loop_hz: 25, loop_max_ms: 42, uptime_s: Math.floor((performance.now() - this.started) / 1000) },
    };
  }
}

// ------------------------------------------------------------------ Anmeldung und REST
const tokens = new Map<string, Role>();

function tokenRole(token: string): Role | null {
  return tokens.get(token) ?? null;
}

function issue(role: Role): string {
  const token = `demo-${role}-${Math.random().toString(36).slice(2)}`;
  tokens.set(token, role);
  try {
    const saved = JSON.parse(window.localStorage.getItem('awc.demoTokens') ?? '{}') as Record<string, Role>;
    saved[token] = role;
    window.localStorage.setItem('awc.demoTokens', JSON.stringify(saved));
  } catch {
    /* Speicher nicht verfügbar */
  }
  return token;
}

function restoreTokens(): void {
  try {
    const saved = JSON.parse(window.localStorage.getItem('awc.demoTokens') ?? '{}') as Record<string, Role>;
    for (const [t, r] of Object.entries(saved)) tokens.set(t, r);
  } catch {
    /* ignorieren */
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

async function handleApi(url: URL, init: RequestInit | undefined): Promise<Response> {
  const method = (init?.method ?? 'GET').toUpperCase();
  const headers = new Headers(init?.headers);
  const auth = headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? '';
  const role = tokenRole(auth);
  const body = init?.body ? JSON.parse(String(init.body)) : {};
  const path = url.pathname;
  const needAdmin = () => (role === 'admin' ? null : json({ detail: role ? 'Administratorrechte erforderlich' : 'Anmeldung erforderlich' }, role ? 403 : 401));

  if (path === '/api/health') return json({ status: 'ok', version: '1.0.0 (Demo)', protocol: 1, mode: 'simulation', state: server.state });
  if (path === '/api/auth/login' && method === 'POST') {
    const wanted = body.role === 'admin' ? 'admin' : 'driver';
    const ok = wanted === 'admin' ? body.secret === DEMO_ADMIN_PASSWORD : body.secret === DEMO_PIN || body.secret === DEMO_ADMIN_PASSWORD;
    if (!ok) return json({ detail: `Zugangsdaten falsch (Demo: PIN ${DEMO_PIN}, Admin ${DEMO_ADMIN_PASSWORD})` }, 401);
    const token = issue(wanted);
    return json({ token, role: wanted, expires_at: Math.floor(Date.now() / 1000) + 12 * 3600 });
  }
  if (!role) return json({ detail: 'Anmeldung erforderlich' }, 401);
  if (path === '/api/auth/me') return json({ role, expires_at: Math.floor(Date.now() / 1000) + 3600 });
  if (path === '/api/settings' && method === 'GET') return json({ version: server.version, settings: server.settings, capabilities: server.capabilities() });
  if (path === '/api/settings' && method === 'PATCH') {
    const denied = needAdmin();
    if (denied) return denied;
    const problem = validatePatch(body.patch ?? {}, true);
    if (problem) return json({ detail: { message: problem, details: [] } }, 422);
    server.applySettings(deepMerge(server.settings as unknown as Record<string, unknown>, body.patch) as unknown as VehicleSettings, 'rest:admin');
    return json({ version: server.version });
  }
  if (path === '/api/settings/reset' && method === 'POST') {
    const denied = needAdmin();
    if (denied) return denied;
    server.applySettings(clone(fixtures.settings) as VehicleSettings, 'rest:zuruecksetzen');
    return json({ version: server.version });
  }
  if (path === '/api/settings/history') return needAdmin() ?? json(server.history.slice(0, 20));
  if (path === '/api/diagnostics/events' && method === 'GET') return json(server.events);
  if (path === '/api/diagnostics/events' && method === 'DELETE') {
    const denied = needAdmin();
    if (denied) return denied;
    server.events = [];
    return json({ ok: true });
  }
  if (path === '/api/diagnostics/faults') return json(fixtures.fault_catalog);
  if (path === '/api/system') {
    return json({
      version: '1.0.0 (Demo)',
      mode: 'simulation',
      tls: true,
      restart_required: false,
      hardware_init_error: null,
      readiness: fixtures.readiness,
      system: {
        model: 'Browser-Demo (kein Raspberry Pi)',
        platform: navigator.platform || 'Browser',
        python: '—',
        cpu_temp_c: null,
        load_avg: null,
        mem_total_mb: null,
        mem_available_mb: null,
        process_rss_mb: null,
        throttled: null,
        uptime_s: Math.floor((performance.now() - server.started) / 1000),
      },
    });
  }
  return json({ detail: 'Nicht gefunden' }, 404);
}

let server: DemoServer;

export function installMockBackend(): void {
  restoreTokens();
  server = new DemoServer();
  const realFetch = window.fetch.bind(window);
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, window.location.href);
    if (url.pathname.startsWith('/api/')) return handleApi(url, init);
    return realFetch(input, init);
  };
  (window as unknown as { WebSocket: unknown }).WebSocket = DemoSocket;
}
