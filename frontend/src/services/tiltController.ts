// Neigungssteuerung über die Bewegungssensoren des Geräts (gemeinsam für alle Ansichten).
//
// * Erzeugt nur im ausdrücklich aktivierten Zustand Lenkanforderungen.
// * iOS/iPadOS: Berechtigung wird ausschließlich aus einer Benutzeraktion angefordert.
// * Ungültige Sensordaten oder ausbleibende Ereignisse (> 300 ms) → Lenkung 0.
// * Beim Deaktivieren werden alle aus der Neigung stammenden Anforderungen sofort zurückgesetzt.
// * Die Kalibrierung der Neutrallage wird je Gerät lokal gespeichert.
// * Vor/Zurück-Neigung als Gas (optional, Standard aus) wirkt nur bei gehaltenem Gaspedal (Totmann).

import { create } from 'zustand';
import { LowPass, anglesFromGravity, steerFromRoll, throttleFromPitch } from '../lib/tilt';
import { held, releaseInput, setInput, useInputView } from '../stores/inputStore';
import { useVehicle } from '../stores/vehicleStore';
import { local } from './storage';

type Permission = 'unknown' | 'granted' | 'denied' | 'not_required';

export interface TiltState {
  supported: boolean;
  secure: boolean;
  permission: Permission;
  active: boolean;
  valid: boolean;
  roll: number;
  pitch: number;
  steer: number;
  error: string | null;
  calibration: { roll: number; pitch: number };
}

const SENSOR_TIMEOUT_MS = 300;

type MotionPermissionApi = { requestPermission?: () => Promise<'granted' | 'denied'> };

export const useTilt = create<TiltState>(() => ({
  supported: typeof window !== 'undefined' && 'DeviceMotionEvent' in window,
  secure: typeof window !== 'undefined' && window.isSecureContext,
  permission: 'unknown',
  active: false,
  valid: false,
  roll: 0,
  pitch: 0,
  steer: 0,
  error: null,
  calibration: local.getJson('awc.tiltCalibration', { roll: 0, pitch: 0 }),
}));

const filter = new LowPass(0.6);
let lastEventAt = 0;
let lastRaw = { roll: 0, pitch: 0, valid: false };
let watchdog: number | undefined;
let lastUiUpdate = 0;

function screenAngle(): number {
  const angle = window.screen?.orientation?.angle;
  if (typeof angle === 'number') return angle;
  const legacy = (window as unknown as { orientation?: number }).orientation;
  return typeof legacy === 'number' ? legacy : 0;
}

function onMotion(event: DeviceMotionEvent): void {
  const state = useTilt.getState();
  if (!state.active) return;
  const g = event.accelerationIncludingGravity;
  const angles = anglesFromGravity(g?.x, g?.y, g?.z, screenAngle());
  const now = performance.now();
  lastEventAt = now;
  lastRaw = angles;
  const settings = useVehicle.getState().settings?.tilt;
  if (!settings) return;
  filter.smoothing = settings.smoothing;
  if (!angles.valid) {
    filter.reset();
    releaseInput('steer');
    if (state.valid) useTilt.setState({ valid: false, steer: 0 });
    return;
  }
  const roll = filter.update(angles.roll);
  const steer = steerFromRoll(roll, state.calibration.roll, settings);
  setInput('steer', steer, 'tilt');
  if (settings.pitch_function === 'throttle' && held.gas) {
    setInput('throttle', throttleFromPitch(angles.pitch, state.calibration.pitch, settings), 'tilt');
  }
  // Anzeige höchstens mit ~20 Hz aktualisieren (Sensor liefert bis zu 60 Hz)
  if (now - lastUiUpdate > 50 || !state.valid) {
    lastUiUpdate = now;
    useTilt.setState({ valid: true, roll, pitch: angles.pitch, steer });
  }
}

export function stopTilt(error: string | null = null): void {
  window.removeEventListener('devicemotion', onMotion);
  window.clearInterval(watchdog);
  filter.reset();
  if (useTilt.getState().active) {
    releaseInput('steer');
    if (useInputView.getState().tiltActive) releaseInput('throttle');
  }
  useInputView.setState({ tiltActive: false });
  useTilt.setState({ active: false, valid: false, steer: 0, error });
}

export async function startTilt(): Promise<void> {
  const { supported, secure } = useTilt.getState();
  if (!supported) {
    useTilt.setState({ error: 'Dieses Gerät meldet keine Bewegungssensoren – manuelle Lenkung aktiv' });
    return;
  }
  if (!secure) {
    useTilt.setState({
      error: 'Bewegungssensoren benötigen eine sichere Verbindung (HTTPS). Siehe Installationsanleitung „TLS“.',
    });
    return;
  }
  const api = window.DeviceMotionEvent as unknown as MotionPermissionApi;
  let permission: Permission = 'not_required';
  if (typeof api.requestPermission === 'function') {
    try {
      permission = (await api.requestPermission()) === 'granted' ? 'granted' : 'denied';
    } catch {
      permission = 'denied';
    }
  }
  if (permission === 'denied') {
    useTilt.setState({ permission, error: 'Zugriff auf Bewegungssensoren wurde verweigert' });
    return;
  }
  filter.reset();
  lastEventAt = performance.now();
  useTilt.setState({ permission, active: true, error: null });
  useInputView.setState({ tiltActive: true });
  window.addEventListener('devicemotion', onMotion);
  window.clearInterval(watchdog);
  watchdog = window.setInterval(() => {
    if (performance.now() - lastEventAt > SENSOR_TIMEOUT_MS) {
      releaseInput('steer');
      if (useTilt.getState().valid) useTilt.setState({ valid: false, steer: 0 });
    }
  }, 100);
  // Desktop-Browser melden die API, liefern aber keine Daten → automatischer Rückfall.
  window.setTimeout(() => {
    if (useTilt.getState().active && performance.now() - lastEventAt > 900) {
      stopTilt('Keine Sensordaten – manuelle Lenkung aktiv');
    }
  }, 1200);
}

export function calibrateTilt(): boolean {
  if (!lastRaw.valid) return false;
  const calibration = { roll: lastRaw.roll, pitch: lastRaw.pitch };
  local.setJson('awc.tiltCalibration', calibration);
  filter.reset();
  useTilt.setState({ calibration });
  return true;
}

export function resetCalibration(): void {
  const calibration = { roll: 0, pitch: 0 };
  local.setJson('awc.tiltCalibration', calibration);
  useTilt.setState({ calibration });
}
