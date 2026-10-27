// Fahransicht (Bild 1): großer Tacho, Bremse links, Gas rechts, Modus/Antrieb oben, Statusleiste unten.

import { ChevronRight, Radio, Zap } from 'lucide-react';
import { useState } from 'react';
import { ArmControl } from '../components/controls/ArmControl';
import { DriveModeList, ProfileTiles, axleIconProps } from '../components/controls/ModeSelectors';
import { PedalPad } from '../components/controls/PedalPad';
import { SteeringControl } from '../components/controls/SteeringControl';
import { ArcGauge } from '../components/gauges/ArcGauge';
import { AxleIcon, BatteryTall, SignalBars, SpeedometerIcon } from '../components/common/Icons';
import { MeasurementValue } from '../components/common/MeasurementValue';
import { Sheet } from '../components/common/Sheet';
import { Segmented } from '../components/common/ui';
import { DriveStatusBar, signalLevel } from '../components/layout/StatusBar';
import { useIsOwner, useTelemetryFresh } from '../hooks/common';
import { effectiveStatus, isCurrent } from '../lib/format';
import { DRIVE_MODE_LABEL, PROFILE_LABEL } from '../lib/labels';
import { command } from '../services/wsClient';
import { useVehicle } from '../stores/vehicleStore';
import type { Direction } from '../types/protocol';

function TopCard({ icon, label, value, onClick, testId }: { icon: React.ReactNode; label: string; value: string; onClick: () => void; testId: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      data-testid={testId}
      className="card flex w-full items-center gap-3 px-3 py-2 text-left transition hover:border-accent/50 sm:gap-4 sm:px-5 sm:py-3"
    >
      <span className="text-accent">{icon}</span>
      <span className="min-w-0 flex-1">
        <span className="block text-xs text-ink-2 sm:text-sm">{label}</span>
        <span className="block truncate text-lg font-semibold text-ink sm:text-[22px]">{value}</span>
      </span>
      <ChevronRight className="h-6 w-6 shrink-0 text-accent" />
    </button>
  );
}

export function DrivePage() {
  const t = useVehicle((s) => s.telemetry);
  const settings = useVehicle((s) => s.settings);
  const fresh = useTelemetryFresh();
  const owner = useIsOwner();
  const [sheet, setSheet] = useState<'profile' | 'drive' | null>(null);

  const speed = t?.measurements.speed_kmh;
  const armed = !!t?.vehicle.armed;
  const gasDisabled = !fresh || !owner || !armed;
  const gasReason = !fresh ? 'Keine Verbindung' : !owner ? 'Nur Beobachter' : !armed ? 'Motoren gesperrt' : undefined;
  const brakeDisabled = !fresh || !owner;
  const direction = t?.vehicle.direction ?? 'forward';
  const dbm = isCurrent(t?.measurements.wifi_signal_dbm, fresh) ? (t!.measurements.wifi_signal_dbm.value as number) : null;
  const battery = t?.measurements.battery_percent;
  const driveMode = t?.vehicle.drive_mode ?? 'awd';

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="drive-grid min-h-0 flex-1 px-3 pb-3 pt-3 sm:px-6 sm:pt-5">
        <div className="drive-mode-card">
          <TopCard
            testId="profile-card"
            icon={<SpeedometerIcon size={30} />}
            label="Modus"
            value={t ? PROFILE_LABEL[t.vehicle.profile] : '—'}
            onClick={() => setSheet('profile')}
          />
        </div>
        <div className="drive-drive-card">
          <TopCard
            testId="drivemode-card"
            icon={<AxleIcon {...axleIconProps(driveMode)} size={30} />}
            label="Antrieb"
            value={t ? DRIVE_MODE_LABEL[driveMode] : '—'}
            onClick={() => setSheet('drive')}
          />
        </div>

        <div className="drive-brake">
          <PedalPad kind="brake" disabled={brakeDisabled} disabledReason={!fresh ? 'Keine Verbindung' : !owner ? 'Nur Beobachter' : undefined} className="h-full w-full" />
        </div>

        <div className="drive-gauge relative flex min-h-0 items-center justify-center">
          <ArcGauge
            value={speed?.value ?? null}
            status={effectiveStatus(speed, fresh)}
            max={settings?.ui.speedometer_max_kmh ?? 30}
            majorStep={(settings?.ui.speedometer_max_kmh ?? 30) > 60 ? 20 : (settings?.ui.speedometer_max_kmh ?? 30) > 30 ? 10 : 5}
            unit="km/h"
            variant="hero"
            ariaLabel="Geschwindigkeit"
            className="h-full max-h-full w-full"
          />
        </div>

        <div className="drive-center-bottom flex flex-col items-center gap-2 sm:gap-3">
          <div className="flex flex-wrap items-center justify-center gap-2 sm:gap-3">
            <Segmented<Direction>
              size="sm"
              value={direction}
              disabled={!owner || !fresh}
              onChange={(d) => command('set_direction', { direction: d })}
              options={[
                { value: 'forward', label: 'V', title: 'Vorwärts' },
                { value: 'reverse', label: 'R', title: 'Rückwärts (nur im Stillstand umschaltbar)' },
              ]}
            />
            <ArmControl />
          </div>
          <div className="drive-stats flex w-full max-w-xl items-center justify-center divide-x divide-line/70 text-ink-2">
            <div className="flex flex-1 items-center justify-center gap-2.5 px-2">
              <Zap className="h-7 w-7 text-accent" />
              <div className="leading-tight">
                <div className="text-[12px]">Spannung</div>
                <div className="text-lg font-medium text-ink">
                  <MeasurementValue m={t?.measurements.battery_voltage} digits={1} unit="V" />
                </div>
              </div>
            </div>
            <div className="flex flex-1 items-center justify-center gap-2.5 px-2">
              <Radio className="h-7 w-7 text-accent" />
              <div className="leading-tight">
                <div className="text-[12px]">Signal</div>
                <SignalBars level={signalLevel(dbm)} className="mt-1 text-accent" />
              </div>
            </div>
            <div className="flex flex-1 items-center justify-center gap-2.5 px-2">
              <BatteryTall percent={isCurrent(battery, fresh) ? battery!.value : null} className="text-ink-2" />
              <div className="leading-tight">
                <div className="text-[12px]">Batterie</div>
                <div className="text-lg font-medium text-ink">
                  <MeasurementValue m={battery} unit="%" />
                </div>
              </div>
            </div>
          </div>
          <div className="w-full max-w-2xl">
            <SteeringControl disabled={!owner || !fresh} showSlider={settings?.ui.show_steering_slider ?? true} />
          </div>
        </div>

        <div className="drive-gas">
          <PedalPad kind="gas" disabled={gasDisabled} disabledReason={gasReason} className="h-full w-full" />
        </div>
      </div>
      <div className="drive-statusbar">
        <DriveStatusBar />
      </div>

      <Sheet open={sheet === 'profile'} title="Fahrprofil wählen" onClose={() => setSheet(null)}>
        <ProfileTiles columns={2} onDone={() => setSheet(null)} />
        {!owner && <p className="mt-3 text-sm text-ink-3">Nur das steuernde Gerät kann das Profil ändern.</p>}
      </Sheet>
      <Sheet open={sheet === 'drive'} title="Antriebsmodus wählen" onClose={() => setSheet(null)}>
        <DriveModeList onDone={() => setSheet(null)} />
      </Sheet>
    </div>
  );
}
