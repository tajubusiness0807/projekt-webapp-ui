// Einstellungen: Neigungssteuerung, Anzeige/Bedienung, Administration (Sicherheit, Akku, Temperatur, Hardware).

import { Crosshair, KeyRound, LogOut, RotateCcw, ShieldAlert, Smartphone } from 'lucide-react';
import { useEffect, useState, type ReactNode } from 'react';
import { SettingSlider } from '../components/controls/SettingSlider';
import { Badge, Button, Card, Notice, Row, Segmented, Toggle } from '../components/common/ui';
import { useIsOwner } from '../hooks/common';
import { formatDateTime, formatNumber } from '../lib/format';
import { DRIVE_MODE_LABEL, PROFILE_LABEL } from '../lib/labels';
import { api, ApiError } from '../services/api';
import { socket } from '../services/wsClient';
import { updateAdminSettings, updateDriverSettings } from '../services/settings';
import { calibrateTilt, resetCalibration, startTilt, stopTilt, useTilt } from '../services/tiltController';
import { useAuth } from '../stores/authStore';
import { toast } from '../stores/toastStore';
import { useVehicle } from '../stores/vehicleStore';
import type { ControllerSettings, DriveModeName, ProfileName, VehicleSettings } from '../types/protocol';

function TiltCard() {
  const settings = useVehicle((s) => s.settings);
  const owner = useIsOwner();
  const tilt = useTilt();
  if (!settings) return null;
  const s = settings.tilt;
  const patch = (field: string, value: unknown) => updateDriverSettings({ tilt: { [field]: value } });
  return (
    <Card
      title="Neigungssteuerung"
      action={
        <Toggle
          label="Neigungssteuerung aktiv"
          checked={tilt.active}
          onChange={async (on) => {
            if (on) {
              await startTilt();
              const err = useTilt.getState().error;
              if (err) toast.warning(err);
            } else stopTilt();
          }}
        />
      }
    >
      {!tilt.secure && (
        <Notice kind="warning">
          Bewegungssensoren sind nur über eine sichere Verbindung (HTTPS) nutzbar. Ohne HTTPS bleibt die manuelle Lenkung aktiv.
        </Notice>
      )}
      {tilt.error && tilt.secure && <Notice kind="warning">{tilt.error}</Notice>}
      <div className="my-3 flex flex-wrap items-center gap-3 rounded-xl border border-line bg-bg-2 p-3">
        <Smartphone className="h-8 w-8 text-accent" style={{ transform: `rotate(${tilt.active ? tilt.roll - tilt.calibration.roll : 0}deg)`, transition: 'transform 80ms linear' }} />
        <div className="min-w-0 flex-1 text-sm">
          <div className="text-ink">
            Neigung: <span className="tabular-nums">{tilt.active && tilt.valid ? `${formatNumber(tilt.roll - tilt.calibration.roll, 1)}°` : '—'}</span> · Lenkung:{' '}
            <span className="tabular-nums">{tilt.active ? `${formatNumber(tilt.steer * 100)} %` : '—'}</span>
          </div>
          <div className="text-xs text-ink-3">
            {tilt.active ? (tilt.valid ? 'Sensordaten gültig' : 'Sensordaten ungültig – Lenkung 0') : 'Deaktiviert – keine Lenkanforderung aus der Neigung'}
          </div>
        </div>
        <Button disabled={!tilt.active} onClick={() => (calibrateTilt() ? toast.success('Neutrallage gespeichert') : toast.warning('Keine gültigen Sensordaten'))}>
          <Crosshair className="h-4 w-4" /> Neutrallage kalibrieren
        </Button>
        <Button tone="ghost" onClick={resetCalibration}>
          Kalibrierung zurücksetzen
        </Button>
      </div>
      <div className="grid gap-x-8 md:grid-cols-2">
        <SettingSlider label="Neigung für volle Lenkung" value={s.full_lock_angle_deg} min={8} max={60} unit="°" disabled={!owner} hint="Kleiner = empfindlicher" onCommit={(v) => patch('full_lock_angle_deg', v)} />
        <SettingSlider label="Maximale Lenkanforderung" value={s.max_steer_percent} min={10} max={100} unit="%" disabled={!owner} onCommit={(v) => patch('max_steer_percent', v)} />
        <SettingSlider label="Totzone" value={s.deadzone_deg} min={0} max={15} unit="°" disabled={!owner} onCommit={(v) => patch('deadzone_deg', v)} />
        <SettingSlider label="Glättung" value={s.smoothing} min={0} max={0.95} step={0.05} digits={2} disabled={!owner} hint="Höher = ruhiger, aber träger" onCommit={(v) => patch('smoothing', v)} />
      </div>
      <Row label="Lenkrichtung umkehren">
        <Toggle label="Lenkrichtung umkehren" checked={s.invert} disabled={!owner} onChange={(v) => patch('invert', v)} />
      </Row>
      <Row label="Vor/Zurück-Neigung" hint="Optional: Gas über Neigung nach vorn – wirkt nur bei gehaltenem Gaspedal">
        <Segmented
          size="sm"
          value={s.pitch_function}
          disabled={!owner}
          onChange={(v) => patch('pitch_function', v)}
          options={[
            { value: 'off', label: 'Aus' },
            { value: 'throttle', label: 'Gas' },
          ]}
        />
      </Row>
      {s.pitch_function === 'throttle' && (
        <div className="grid gap-x-8 md:grid-cols-2">
          <SettingSlider label="Neigung für volles Gas" value={s.pitch_full_angle_deg} min={5} max={45} unit="°" disabled={!owner} onCommit={(v) => patch('pitch_full_angle_deg', v)} />
          <SettingSlider label="Totzone vor/zurück" value={s.pitch_deadzone_deg} min={0} max={20} unit="°" disabled={!owner} onCommit={(v) => patch('pitch_deadzone_deg', v)} />
        </div>
      )}
    </Card>
  );
}

function DisplayCard() {
  const settings = useVehicle((s) => s.settings);
  const owner = useIsOwner();
  if (!settings) return null;
  const ui = settings.ui;
  const patch = (section: string, field: string, value: unknown) => updateDriverSettings({ [section]: { [field]: value } });
  return (
    <Card title="Anzeige & Bedienung">
      <SettingSlider label="Tacho-Skala bis" value={ui.speedometer_max_kmh} min={10} max={120} step={5} unit="km/h" disabled={!owner} onCommit={(v) => patch('ui', 'speedometer_max_kmh', v)} />
      <SettingSlider label="Drehzahl-Skala bis" value={ui.rpm_gauge_max} min={200} max={5000} step={100} unit="U/min" disabled={!owner} onCommit={(v) => patch('ui', 'rpm_gauge_max', v)} />
      <SettingSlider label="Gas per Tastatur" value={ui.keyboard_throttle_percent} min={10} max={100} unit="%" disabled={!owner} onCommit={(v) => patch('ui', 'keyboard_throttle_percent', v)} />
      <Row label="Gaspedal" hint="Proportional: Fingerhöhe bestimmt die Gasstellung">
        <Segmented
          size="sm"
          value={ui.pedal_mode}
          disabled={!owner}
          onChange={(v) => patch('ui', 'pedal_mode', v)}
          options={[
            { value: 'proportional', label: 'Proportional' },
            { value: 'full', label: 'Voll' },
          ]}
        />
      </Row>
      <Row label="Haptisches Feedback">
        <Toggle label="Haptisches Feedback" checked={ui.haptic_feedback} disabled={!owner} onChange={(v) => patch('ui', 'haptic_feedback', v)} />
      </Row>
      <Row label="Lenkregler anzeigen" hint="Manuelle Lenkung, wenn die Neigung aus ist">
        <Toggle label="Lenkregler anzeigen" checked={ui.show_steering_slider} disabled={!owner} onChange={(v) => patch('ui', 'show_steering_slider', v)} />
      </Row>
      <Row label="Standard-Fahrprofil" hint="Gilt nach jedem Start">
        <select className="select" value={settings.general.default_profile} disabled={!owner} onChange={(e) => patch('general', 'default_profile', e.target.value)}>
          {(['eco', 'normal', 'sport', 'custom'] as ProfileName[]).map((p) => (
            <option key={p} value={p}>
              {PROFILE_LABEL[p]}
            </option>
          ))}
        </select>
      </Row>
      <Row label="Standard-Antriebsmodus">
        <select className="select" value={settings.general.default_drive_mode} disabled={!owner} onChange={(e) => patch('general', 'default_drive_mode', e.target.value)}>
          {(['awd', 'fwd', 'rwd', 'custom'] as DriveModeName[]).map((m) => (
            <option key={m} value={m}>
              {DRIVE_MODE_LABEL[m]}
            </option>
          ))}
        </select>
      </Row>
    </Card>
  );
}

function AdminLogin() {
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const setAdmin = useAuth((s) => s.setAdmin);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const result = await api.login(password, 'admin');
      setAdmin(result.token);
      setPassword('');
      toast.success('Als Administrator angemeldet');
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Anmeldung fehlgeschlagen');
    }
  };
  return (
    <form onSubmit={submit} className="flex flex-wrap items-end gap-3">
      <label className="min-w-[220px] flex-1 text-sm text-ink-2">
        Administrator-Passwort
        <input type="password" autoComplete="current-password" className="input mt-1 w-full" value={password} onChange={(e) => setPassword(e.target.value)} />
      </label>
      <Button type="submit" tone="primary" disabled={!password}>
        <KeyRound className="h-4 w-4" /> Anmelden
      </Button>
      {error && <p className="w-full text-sm text-danger">{error}</p>}
    </form>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="mt-5 first:mt-0">
      <h3 className="mb-1 text-sm font-semibold uppercase tracking-wide text-ink-3">{title}</h3>
      {children}
    </div>
  );
}

function TextField({ label, value, onCommit, placeholder }: { label: string; value: string; onCommit: (v: string) => void; placeholder?: string }) {
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  return (
    <Row label={label}>
      <input
        className="input w-56"
        value={draft}
        placeholder={placeholder}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={() => draft !== value && onCommit(draft)}
        onKeyDown={(e) => e.key === 'Enter' && (e.target as HTMLInputElement).blur()}
      />
    </Row>
  );
}

function ControllerEditor({ settings }: { settings: VehicleSettings }) {
  const controllers = settings.hardware.controllers;
  const save = (id: 'A' | 'B', changes: Partial<ControllerSettings>) => {
    let next = controllers.map((c) => (c.id === id ? { ...c, ...changes } : c));
    if (changes.axle) {
      // Achszuordnung tauschen, damit immer genau eine Vorder- und eine Hinterachse existiert.
      next = next.map((c) => (c.id !== id ? { ...c, axle: changes.axle === 'front' ? 'rear' : 'front' } : c));
    }
    return updateAdminSettings({ hardware: { controllers: next } });
  };
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      {controllers.map((c) => (
        <div key={c.id} className="rounded-xl border border-line bg-bg-2/60 p-3">
          <div className="mb-2 flex items-center justify-between">
            <strong className="text-ink">Controller {c.id}</strong>
            <Segmented
              size="sm"
              value={c.axle}
              onChange={(axle) => save(c.id, { axle })}
              options={[
                { value: 'front', label: 'Vorderachse' },
                { value: 'rear', label: 'Hinterachse' },
              ]}
            />
          </div>
          <TextField label="Serielle Schnittstelle" value={c.port} placeholder="/dev/ttyUSB0" onCommit={(port) => save(c.id, { port })} />
          <Row label="Baudrate">
            <select className="select" value={c.baudrate} onChange={(e) => save(c.id, { baudrate: Number(e.target.value) })}>
              {[9600, 19200, 38400, 57600, 115200, 230400].map((b) => (
                <option key={b} value={b}>
                  {b}
                </option>
              ))}
            </select>
          </Row>
          <SettingSlider label="Max. Rohbefehl (±1000)" value={c.max_command} min={50} max={1000} step={10} onCommit={(v) => save(c.id, { max_command: v })} hint="Für erste Tests klein halten" />
          <SettingSlider label="SPEED_COEFFICIENT" value={c.speed_coefficient} min={0.1} max={2} step={0.05} digits={2} onCommit={(v) => save(c.id, { speed_coefficient: v })} />
          <SettingSlider label="STEER_COEFFICIENT" value={c.steer_coefficient} min={0} max={2} step={0.05} digits={2} onCommit={(v) => save(c.id, { steer_coefficient: v })} />
          {(
            [
              ['feedback_with_odometry', 'Feedback mit Odometrie (22 Byte)'],
              ['invert_left_command', 'Befehl links invertieren'],
              ['invert_right_command', 'Befehl rechts invertieren'],
              ['invert_left_feedback', 'Rückmeldung links invertieren'],
              ['invert_right_feedback', 'Rückmeldung rechts invertieren'],
              ['swap_sides', 'Seiten tauschen'],
            ] as [keyof ControllerSettings, string][]
          ).map(([field, label]) => (
            <Row key={field} label={label}>
              <Toggle label={label} checked={Boolean(c[field])} onChange={(v) => save(c.id, { [field]: v } as Partial<ControllerSettings>)} />
            </Row>
          ))}
        </div>
      ))}
    </div>
  );
}

function AdminCard() {
  const settings = useVehicle((s) => s.settings);
  const caps = useVehicle((s) => s.capabilities);
  const adminToken = useAuth((s) => s.adminToken);
  const setAdmin = useAuth((s) => s.setAdmin);
  const [history, setHistory] = useState<{ version: number; created_at: number; source: string }[]>([]);
  const [confirmReset, setConfirmReset] = useState(false);

  useEffect(() => {
    if (!adminToken) return;
    api.settingsHistory(adminToken).then(setHistory).catch(() => setHistory([]));
  }, [adminToken, settings]);

  if (!settings) return null;
  const a = (section: string, field: string, value: unknown) => updateAdminSettings({ [section]: { [field]: value } });
  const hw = settings.hardware;
  const sf = settings.safety;
  const bat = settings.battery;
  const temp = settings.temperature;

  return (
    <Card
      title={
        <span className="flex items-center gap-2">
          <ShieldAlert className="h-5 w-5 text-warn" /> Administration
        </span>
      }
      className="lg:col-span-2"
      action={
        adminToken ? (
          <Button tone="ghost" onClick={() => setAdmin(null)}>
            <LogOut className="h-4 w-4" /> Admin abmelden
          </Button>
        ) : undefined
      }
    >
      {!adminToken ? (
        <>
          <p className="mb-3 text-sm text-ink-2">Sicherheitsgrenzen, Akku, Temperaturen, Hardware und Controller sind durch das Administrator-Passwort geschützt.</p>
          <AdminLogin />
        </>
      ) : (
        <div>
          {caps?.restart_required && <Notice kind="warning">Hardware-Einstellungen wurden geändert. Sie werden erst nach einem Neustart des Dienstes wirksam.</Notice>}

          <Section title="Sicherheitsgrenzen">
            <div className="grid gap-x-8 md:grid-cols-2">
              <SettingSlider label="Absolute Höchstgeschwindigkeit" value={sf.absolute_max_speed_kmh} min={2} max={40} unit="km/h" onCommit={(v) => a('safety', 'absolute_max_speed_kmh', v)} />
              <SettingSlider label="Absolute max. Gasstellung" value={sf.absolute_max_throttle_percent} min={10} max={100} unit="%" onCommit={(v) => a('safety', 'absolute_max_throttle_percent', v)} />
              <SettingSlider label="Absolute max. Rampe" value={sf.absolute_max_accel_ramp_percent_per_s} min={10} max={400} unit="%/s" onCommit={(v) => a('safety', 'absolute_max_accel_ramp_percent_per_s', v)} />
              <SettingSlider label="Rückwärts max. Geschwindigkeit" value={sf.reverse_max_speed_kmh} min={1} max={10} unit="km/h" onCommit={(v) => a('safety', 'reverse_max_speed_kmh', v)} />
              <SettingSlider label="Rückwärts max. Gas" value={sf.reverse_max_throttle_percent} min={10} max={60} unit="%" onCommit={(v) => a('safety', 'reverse_max_throttle_percent', v)} />
              <SettingSlider label="Stillstandsschwelle" value={sf.standstill_speed_kmh} min={0.2} max={3} step={0.1} digits={1} unit="km/h" onCommit={(v) => a('safety', 'standstill_speed_kmh', v)} />
              <SettingSlider label="Befehls-Timeout (Totmann)" value={sf.command_timeout_ms} min={100} max={1000} step={10} unit="ms" onCommit={(v) => a('safety', 'command_timeout_ms', v)} />
              <SettingSlider label="Verbindungs-Timeout" value={sf.connection_timeout_ms} min={300} max={5000} step={50} unit="ms" onCommit={(v) => a('safety', 'connection_timeout_ms', v)} />
              <SettingSlider label="Controller-Timeout" value={sf.controller_timeout_ms} min={100} max={3000} step={50} unit="ms" onCommit={(v) => a('safety', 'controller_timeout_ms', v)} />
              <SettingSlider label="Messwerte veraltet nach" value={sf.telemetry_stale_ms} min={200} max={5000} step={50} unit="ms" onCommit={(v) => a('safety', 'telemetry_stale_ms', v)} />
              <SettingSlider label="Max. Befehlsalter" value={sf.max_command_age_ms} min={100} max={2000} step={50} unit="ms" onCommit={(v) => a('safety', 'max_command_age_ms', v)} />
              <SettingSlider label="Max. Befehlsrate" value={sf.max_command_rate_hz} min={5} max={60} unit="Hz" onCommit={(v) => a('safety', 'max_command_rate_hz', v)} />
              <SettingSlider label="Regelschleife hängt nach" value={sf.loop_stall_ms} min={200} max={3000} step={50} unit="ms" onCommit={(v) => a('safety', 'loop_stall_ms', v)} />
              <SettingSlider label="Max. gleichzeitige Geräte" value={sf.max_sessions} min={1} max={8} onCommit={(v) => a('safety', 'max_sessions', v)} />
            </div>
          </Section>

          <Section title="Akku">
            <div className="grid gap-x-8 md:grid-cols-2">
              <SettingSlider label="Zellen in Reihe" value={bat.cells_series} min={6} max={16} unit="S" onCommit={(v) => a('battery', 'cells_series', v)} />
              <SettingSlider label="Zelle voll" value={bat.cell_full_v} min={3.9} max={4.25} step={0.01} digits={2} unit="V" onCommit={(v) => a('battery', 'cell_full_v', v)} />
              <SettingSlider label="Zelle Warnung" value={bat.cell_warning_v} min={3} max={3.9} step={0.01} digits={2} unit="V" onCommit={(v) => a('battery', 'cell_warning_v', v)} />
              <SettingSlider label="Zelle kritisch" value={bat.cell_critical_v} min={2.9} max={3.8} step={0.01} digits={2} unit="V" onCommit={(v) => a('battery', 'cell_critical_v', v)} />
              <SettingSlider label="Zelle leer" value={bat.cell_empty_v} min={2.8} max={3.6} step={0.01} digits={2} unit="V" onCommit={(v) => a('battery', 'cell_empty_v', v)} />
            </div>
            {caps && (
              <p className="text-xs text-ink-3">
                Pack: voll {formatNumber(caps.battery_limits.full_v, 1)} V · Warnung {formatNumber(caps.battery_limits.warning_v, 1)} V · kritisch{' '}
                {formatNumber(caps.battery_limits.critical_v, 1)} V
              </p>
            )}
          </Section>

          <Section title="Temperaturen">
            <div className="grid gap-x-8 md:grid-cols-2">
              <SettingSlider label="Controller Warnung" value={temp.controller_warning_c} min={30} max={90} unit="°C" onCommit={(v) => a('temperature', 'controller_warning_c', v)} />
              <SettingSlider label="Controller kritisch" value={temp.controller_critical_c} min={35} max={100} unit="°C" onCommit={(v) => a('temperature', 'controller_critical_c', v)} />
              <SettingSlider label="Motor Warnung" value={temp.motor_warning_c} min={30} max={120} unit="°C" onCommit={(v) => a('temperature', 'motor_warning_c', v)} />
              <SettingSlider label="Motor kritisch" value={temp.motor_critical_c} min={35} max={140} unit="°C" onCommit={(v) => a('temperature', 'motor_critical_c', v)} />
            </div>
          </Section>

          <Section title="Hardware (wirksam nach Neustart)">
            <Notice kind="warning">
              Den Hardwaremodus erst aktivieren, wenn alle Punkte in <strong>docs/hardware.md</strong> geprüft sind. Zusätzlich muss
              <code className="mx-1">AWC_HARDWARE_ENABLED=1</code>in der Dienstkonfiguration gesetzt sein.
            </Notice>
            <Row label="Betriebsart">
              <Segmented
                size="sm"
                value={hw.mode}
                onChange={(v) => a('hardware', 'mode', v)}
                options={[
                  { value: 'simulation', label: 'Simulation' },
                  { value: 'hardware', label: 'Hardware' },
                ]}
              />
            </Row>
            <TextField label="Mainboard-Typ" value={hw.controller_model} placeholder="z. B. STM32F103RCT6" onCommit={(v) => a('hardware', 'controller_model', v)} />
            <Row label="Firmware">
              <select className="select" value={hw.firmware} onChange={(e) => a('hardware', 'firmware', e.target.value)}>
                <option value="unknown">unbekannt</option>
                <option value="hoverboard-firmware-hack-foc">hoverboard-firmware-hack-FOC</option>
              </select>
            </Row>
            <TextField label="Firmware-Version / Commit" value={hw.firmware_version} onCommit={(v) => a('hardware', 'firmware_version', v)} />
            <Row label="Regelmodus der Firmware">
              <select className="select" value={hw.firmware_control_mode} onChange={(e) => a('hardware', 'firmware_control_mode', e.target.value)}>
                <option value="unknown">unbekannt</option>
                <option value="voltage">Spannung (VLT_MODE)</option>
                <option value="speed">Drehzahl (SPD_MODE)</option>
                <option value="torque">Drehmoment (TRQ_MODE)</option>
              </select>
            </Row>
            <SettingSlider label="Raddurchmesser" value={hw.wheel_diameter_m * 1000} min={80} max={600} unit="mm" onCommit={(v) => a('hardware', 'wheel_diameter_m', v / 1000)} />
            <Row label="Bremsmethode" hint="Nur nach Prüfung am aufgebockten Fahrzeug">
              <select className="select" value={hw.brake_method} onChange={(e) => a('hardware', 'brake_method', e.target.value)}>
                <option value="none">keine (nur Antrieb aus)</option>
                <option value="voltage_mode_zero">Nullbefehl im VLT_MODE</option>
                <option value="counter_torque">Gegenmoment im TRQ_MODE</option>
              </select>
            </Row>
            {(
              [
                ['firmware_variant_usart', 'Firmware mit USART-Steuerung und -Feedback'],
                ['protocol_verified', 'Protokoll geprüft (gültiges Feedback empfangen)'],
                ['signal_levels_verified', 'Signalpegel 3,3 V geprüft, 15-V-Ader nicht angeschlossen'],
                ['wiring_verified', 'Verkabelung, Sicherungen, Hardware-Not-Aus geprüft'],
                ['independent_axle_control', 'Beide Controller unabhängig ansteuerbar'],
                ['wheel_diameter_verified', 'Raddurchmesser nachgemessen'],
                ['temperature_calibrated', 'Temperatur der Boards kalibriert'],
                ['brake_verified', 'Bremsmethode verifiziert'],
                ['wheels_lifted_test_passed', 'Test mit aufgebockten Rädern bestanden'],
              ] as [keyof VehicleSettings['hardware'], string][]
            ).map(([field, label]) => (
              <Row key={field} label={label}>
                <Toggle label={label} checked={Boolean(hw[field])} onChange={(v) => a('hardware', field, v)} />
              </Row>
            ))}
          </Section>

          <Section title="Controller-Zuordnung">
            <ControllerEditor settings={settings} />
          </Section>

          <Section title="Telemetrie">
            <div className="grid gap-x-8 md:grid-cols-2">
              <SettingSlider label="Telemetrie-Rate" value={settings.telemetry.broadcast_hz} min={2} max={20} unit="Hz" onCommit={(v) => a('telemetry', 'broadcast_hz', v)} />
              <SettingSlider label="Regelschleife" value={settings.telemetry.control_loop_hz} min={10} max={50} unit="Hz" onCommit={(v) => a('telemetry', 'control_loop_hz', v)} />
            </div>
          </Section>

          <Section title="Zurücksetzen & Versionen">
            <div className="flex flex-wrap items-center gap-3">
              {!confirmReset ? (
                <Button tone="danger" onClick={() => setConfirmReset(true)}>
                  <RotateCcw className="h-4 w-4" /> Auf sichere Standardwerte zurücksetzen
                </Button>
              ) : (
                <>
                  <span className="text-sm text-warn">Alle Einstellungen inkl. Hardware zurücksetzen?</span>
                  <Button
                    tone="danger"
                    onClick={async () => {
                      setConfirmReset(false);
                      try {
                        await api.resetSettings(adminToken);
                        toast.success('Sichere Standardwerte geladen');
                      } catch (e) {
                        toast.error((e as Error).message);
                      }
                    }}
                  >
                    Ja, zurücksetzen
                  </Button>
                  <Button tone="ghost" onClick={() => setConfirmReset(false)}>
                    Abbrechen
                  </Button>
                </>
              )}
            </div>
            <div className="mt-3 max-h-48 overflow-y-auto rounded-xl border border-line">
              {history.map((h) => (
                <div key={h.version} className="flex justify-between border-b border-line/60 px-3 py-1.5 text-xs last:border-0">
                  <span className="text-ink">Version {h.version}</span>
                  <span className="text-ink-3">{h.source}</span>
                  <span className="tabular-nums text-ink-3">{formatDateTime(h.created_at)}</span>
                </div>
              ))}
            </div>
          </Section>
        </div>
      )}
    </Card>
  );
}

export function SettingsPage() {
  const owner = useIsOwner();
  const logout = useAuth((s) => s.logout);
  const version = useVehicle((s) => s.settingsVersion);
  return (
    <div className="page-grid">
      {!owner && (
        <div className="lg:col-span-2">
          <Notice>Fahreinstellungen kann nur das steuernde Gerät ändern. Steuerung in der Fahransicht übernehmen.</Notice>
        </div>
      )}
      <TiltCard />
      <DisplayCard />
      <AdminCard />
      <div className="flex items-center justify-between lg:col-span-2">
        <span className="text-xs text-ink-3">
          Einstellungsversion <Badge>{version}</Badge>
        </span>
        <Button
          tone="ghost"
          onClick={() => {
            socket.stop();
            logout();
          }}
        >
          <LogOut className="h-4 w-4" /> Abmelden
        </Button>
      </div>
    </div>
  );
}
