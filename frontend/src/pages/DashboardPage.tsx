// Übersicht (Bild 2): Instrumente mit Fahrzeugdraufsicht, Fahrmodus, Steuerung, Leistung, Einstellungen.

import { Battery, Gauge, Minus, Move, Plus, ShieldCheck, Square } from 'lucide-react';
import { ArmControl } from '../components/controls/ArmControl';
import { Joystick } from '../components/controls/Joystick';
import { DriveModeList, ProfileTiles } from '../components/controls/ModeSelectors';
import { PowerSplitControl } from '../components/controls/PowerSplit';
import { SettingSlider } from '../components/controls/SettingSlider';
import { ArcGauge } from '../components/gauges/ArcGauge';
import { Card, Toggle } from '../components/common/ui';
import { DashboardStatusBar } from '../components/layout/StatusBar';
import { VehicleTopView } from '../components/vehicle/VehicleTopView';
import { useIsOwner, useTelemetryFresh } from '../hooks/common';
import { effectiveStatus } from '../lib/format';
import { socket } from '../services/wsClient';
import { updateDriverSettings } from '../services/settings';
import { releaseAllInputs } from '../stores/inputStore';
import { toast } from '../stores/toastStore';
import { useVehicle } from '../stores/vehicleStore';

function SettingsCard() {
  const settings = useVehicle((s) => s.settings);
  const profileName = useVehicle((s) => s.telemetry?.vehicle.profile ?? 'eco');
  const owner = useIsOwner();
  if (!settings) return null;
  const profile = settings.profiles[profileName];
  const absMax = settings.safety.absolute_max_speed_kmh;
  const patchProfile = (field: string, value: number) => updateDriverSettings({ profiles: { [profileName]: { [field]: value } } });
  return (
    <Card title="Weitere Einstellungen">
      <div className="divide-y divide-line/60">
        <SettingSlider
          icon={<Move className="h-4 w-4" />}
          label="Lenkempfindlichkeit"
          value={profile.steering_sensitivity_percent}
          min={10}
          max={100}
          unit="%"
          disabled={!owner}
          onCommit={(v) => patchProfile('steering_sensitivity_percent', v)}
        />
        <SettingSlider
          icon={<Gauge className="h-4 w-4" />}
          label="Max. Geschwindigkeit"
          value={profile.max_speed_kmh}
          min={1}
          max={absMax}
          unit="km/h"
          disabled={!owner}
          hint={profile.max_speed_kmh > absMax ? `Begrenzt auf ${absMax} km/h (Sicherheitsgrenze)` : undefined}
          onCommit={(v) => patchProfile('max_speed_kmh', v)}
        />
        <SettingSlider
          icon={<Plus className="h-4 w-4" />}
          label="Beschleunigung"
          value={profile.accel_ramp_percent_per_s}
          min={5}
          max={settings.safety.absolute_max_accel_ramp_percent_per_s}
          unit="%/s"
          disabled={!owner}
          onCommit={(v) => patchProfile('accel_ramp_percent_per_s', v)}
        />
        <div className="flex items-center gap-3 py-3">
          <Battery className="h-4 w-4 text-ink-2" />
          <div className="flex-1 text-sm text-ink-2">
            Batterie-Schutz
            <div className="text-xs text-ink-3">Leistung unter der Warnschwelle reduzieren</div>
          </div>
          <Toggle
            label="Batterie-Schutz"
            checked={settings.battery.protection_enabled}
            disabled={!owner}
            onChange={(v) => updateDriverSettings({ battery: { protection_enabled: v } })}
          />
        </div>
        <div className="flex items-center gap-3 py-3">
          <ShieldCheck className="h-4 w-4 text-ink-2" />
          <div className="flex-1 text-sm text-ink-2">
            Autom. Stopp bei Verbindungsausfall
            <div className="text-xs text-ink-3">Sicherheitsfunktion – immer aktiv</div>
          </div>
          <Toggle label="Autom. Stopp bei Verbindungsausfall" checked locked />
        </div>
      </div>
    </Card>
  );
}

export function DashboardPage() {
  const t = useVehicle((s) => s.telemetry);
  const settings = useVehicle((s) => s.settings);
  const fresh = useTelemetryFresh();
  const owner = useIsOwner();
  const out = t?.control.output;
  const profileName = t?.vehicle.profile ?? 'eco';
  const absMax = settings?.safety.absolute_max_speed_kmh ?? 20;
  const currentMax = settings?.profiles[profileName].max_speed_kmh ?? 10;

  const adjustSpeed = (delta: number) => {
    const next = Math.max(1, Math.min(absMax, currentMax + delta));
    if (next !== currentMax) void updateDriverSettings({ profiles: { [profileName]: { max_speed_kmh: next } } }, `Max. Geschwindigkeit ${next} km/h`);
  };

  const stop = async () => {
    releaseAllInputs();
    const ack = await socket.request('estop', { reason: 'STOP-Taste Übersicht' });
    if (!ack.ok) toast.error('STOP nicht bestätigt – Hardware-Not-Aus benutzen!');
  };

  const rpmMax = settings?.ui.rpm_gauge_max ?? 1000;
  const speedMax = settings?.ui.speedometer_max_kmh ?? 30;

  return (
    <div className="dashboard-grid">
      <Card className="dash-instruments flex items-center" padded={false}>
        <div className="grid w-full grid-cols-1 items-center gap-2 p-3 sm:grid-cols-[1fr_0.75fr_1fr] sm:p-4">
          <ArcGauge
            variant="compact"
            value={t?.measurements.speed_kmh.value ?? null}
            status={effectiveStatus(t?.measurements.speed_kmh, fresh)}
            max={speedMax}
            majorStep={speedMax > 60 ? 20 : speedMax > 30 ? 10 : 5}
            unit="km/h"
            caption="Geschwindigkeit"
            ariaLabel="Geschwindigkeit"
            colors={['#1c6dff', '#2f8bff', '#3b5bff']}
            className="mx-auto w-full max-w-[320px]"
          />
          <VehicleTopView
            className="mx-auto hidden h-full max-h-[320px] w-full sm:block"
            front={out?.front ?? { left: 0, right: 0 }}
            rear={out?.rear ?? { left: 0, right: 0 }}
            frontScale={t?.control.split.front_scale ?? 1}
            rearScale={t?.control.split.rear_scale ?? 1}
            braking={(out?.brake_level ?? 0) > 0}
            mode={t?.vehicle.drive_mode ?? 'awd'}
          />
          <ArcGauge
            variant="compact"
            value={t?.measurements.motor_rpm.value ?? null}
            status={effectiveStatus(t?.measurements.motor_rpm, fresh)}
            max={rpmMax}
            majorStep={rpmMax >= 2000 ? 1000 : rpmMax >= 1000 ? 200 : 100}
            minorPerMajor={rpmMax >= 2000 ? 5 : 4}
            unit="U/min"
            caption="Drehzahl"
            ariaLabel="Motordrehzahl"
            colors={['#1de9b0', '#22c5c0', '#2f7bff']}
            className="mx-auto w-full max-w-[320px]"
          />
        </div>
      </Card>

      <Card title="Fahrmodus" className="dash-modes">
        <DriveModeList compact />
        <div className="mt-4">
          <ProfileTiles />
        </div>
      </Card>

      <Card title="Steuerung" action={<ArmControl compact />} className="dash-control">
        <div className="flex flex-col items-center gap-5 sm:flex-row sm:justify-around">
          <Joystick disabled={!owner || !fresh || !t?.vehicle.armed} size={210} />
          <div className="flex w-full max-w-[150px] flex-col gap-3">
            <button
              type="button"
              onClick={stop}
              className="flex flex-col items-center gap-1 rounded-xl border border-line-strong bg-bg-2 py-3 text-sm font-medium text-ink hover:border-danger"
              title="Not-Aus"
            >
              <Square className="h-5 w-5 fill-danger text-danger" />
              STOP
            </button>
            <button
              type="button"
              disabled={!owner}
              onClick={() => adjustSpeed(1)}
              className="flex flex-col items-center gap-1 rounded-xl border border-line-strong bg-bg-2 py-3 text-sm text-ink hover:border-accent disabled:opacity-40"
              title="Geschwindigkeitsgrenze +1 km/h"
            >
              <Plus className="h-5 w-5" />
              Schneller
            </button>
            <button
              type="button"
              disabled={!owner}
              onClick={() => adjustSpeed(-1)}
              className="flex flex-col items-center gap-1 rounded-xl border border-line-strong bg-bg-2 py-3 text-sm text-ink hover:border-accent disabled:opacity-40"
              title="Geschwindigkeitsgrenze −1 km/h"
            >
              <Minus className="h-5 w-5" />
              Langsamer
            </button>
          </div>
        </div>
      </Card>

      <Card title="Leistung" className="dash-power">
        <PowerSplitControl />
      </Card>

      <div className="dash-settings">
        <SettingsCard />
      </div>

      <div className="dash-status">
        <DashboardStatusBar />
      </div>
    </div>
  );
}
