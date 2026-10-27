import { CheckCircle2, Clock, Leaf, Thermometer, Wifi, XCircle, Zap } from 'lucide-react';
import type { ReactNode } from 'react';
import { useTelemetryFresh } from '../../hooks/common';
import { formatDuration, formatHours, formatNumber, isCurrent } from '../../lib/format';
import { PROFILE_DESCRIPTION, PROFILE_LABEL } from '../../lib/labels';
import { useVehicle } from '../../stores/vehicleStore';
import { BatteryTall, SignalBars } from '../common/Icons';
import { MeasurementValue } from '../common/MeasurementValue';

function Item({
  icon,
  label,
  short,
  children,
  sub,
  bar,
}: {
  icon: ReactNode;
  label: string;
  short?: string;
  children: ReactNode;
  sub?: ReactNode;
  bar?: ReactNode;
}) {
  return (
    <div className="flex min-w-0 flex-1 items-center gap-2 px-2.5 py-2 sm:gap-3 sm:px-5">
      <div className="shrink-0 text-ink-2">{icon}</div>
      <div className="min-w-0 flex-1">
        <div className="truncate text-[12px] text-ink-2">
          {short ? (
            <>
              <span className="sm:hidden">{short}</span>
              <span className="hidden sm:inline">{label}</span>
            </>
          ) : (
            label
          )}
        </div>
        <div className="truncate text-[17px] font-medium text-ink">{children}</div>
        {sub && <div className="truncate text-[11px] text-ink-3">{sub}</div>}
        {bar}
      </div>
    </div>
  );
}

function Bar({ value, color }: { value: number | null; color: string }) {
  return (
    <div className="mt-1.5 h-1.5 w-full max-w-[200px] overflow-hidden rounded-full bg-bg-4">
      <div className="h-full rounded-full transition-[width] duration-500" style={{ width: `${Math.max(0, Math.min(100, value ?? 0))}%`, background: color }} />
    </div>
  );
}

export function signalLevel(dbm: number | null): number {
  if (dbm === null) return 0;
  if (dbm >= -55) return 4;
  if (dbm >= -67) return 3;
  if (dbm >= -75) return 2;
  return 1;
}

const QUALITY_LABEL = { stark: 'Stark', gut: 'Gut', mittel: 'Mittel', schwach: 'Schwach', unbekannt: 'Unbekannt' } as const;

/** Statusleiste der Fahransicht (Bild 1): Batterie, Controller-Temperatur, Verbindung. */
export function DriveStatusBar() {
  const t = useVehicle((s) => s.telemetry);
  const fresh = useTelemetryFresh();
  const battery = t?.measurements.battery_percent;
  const quality = fresh ? (t?.measurements.wifi_quality ?? 'unbekannt') : 'unbekannt';
  const qualityColor = { stark: 'text-ok', gut: 'text-ok', mittel: 'text-warn', schwach: 'text-danger', unbekannt: 'text-ink-3' }[quality];
  return (
    <footer className="safe-bottom flex shrink-0 divide-x divide-line/70 border-t border-line/80 bg-bg-1/70">
      <Item icon={<BatteryTall percent={isCurrent(battery, fresh) ? battery!.value : null} />} label="Batterie">
        <MeasurementValue m={battery} unit="%" />
      </Item>
      <Item icon={<Thermometer className="h-7 w-7" />} label="Controller Temperatur" short="Controller">
        <MeasurementValue m={t?.measurements.controller_temp_c} digits={0} unit="°C" />
      </Item>
      <Item icon={<Wifi className="h-7 w-7" />} label="Verbindung" short="WLAN">
        <span className={qualityColor}>{fresh ? QUALITY_LABEL[quality] : 'Getrennt'}</span>
      </Item>
    </footer>
  );
}

/** Statusleiste der Übersicht (Bild 2). */
export function DashboardStatusBar() {
  const t = useVehicle((s) => s.telemetry);
  const caps = useVehicle((s) => s.capabilities);
  const fresh = useTelemetryFresh();
  const m = t?.measurements;
  const limits = caps?.battery_limits;
  const blocking = t?.faults.filter((f) => f.blocking) ?? [];
  const front = t?.controllers.find((c) => c.axle === 'front');
  const rear = t?.controllers.find((c) => c.axle === 'rear');
  const profile = t?.vehicle.profile ?? 'eco';
  const dbm = isCurrent(m?.wifi_signal_dbm, fresh) ? (m!.wifi_signal_dbm.value as number) : null;
  return (
    <section className="card grid grid-cols-2 gap-y-2 py-2 sm:grid-cols-3 xl:grid-cols-6 xl:divide-x xl:divide-line/70">
      <Item
        icon={
          <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-ok-soft text-ok-2">
            <Zap className="h-6 w-6" />
          </div>
        }
        label="Batterie"
        sub={
          <>
            <MeasurementValue m={m?.battery_voltage} digits={1} unit="V" showTag={false} /> / {limits ? `${formatNumber(limits.full_v, 1)} V` : '—'}
          </>
        }
        bar={<Bar value={isCurrent(m?.battery_percent, fresh) ? (m!.battery_percent.value as number) : null} color="linear-gradient(90deg,#16c172,#22e08a)" />}
      >
        <MeasurementValue m={m?.battery_percent} unit="%" />
      </Item>
      <Item
        icon={
          <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-bg-4 text-ink-2">
            <Thermometer className="h-6 w-6" />
          </div>
        }
        label="Temperatur"
        sub={
          <>
            Motor: <MeasurementValue m={m?.motor_temp_c} unit="°C" showTag={false} /> | Controller:{' '}
            <MeasurementValue m={m?.controller_temp_c} unit="°C" showTag={false} />
          </>
        }
        bar={<Bar value={isCurrent(m?.controller_temp_c, fresh) ? ((m!.controller_temp_c.value as number) / 80) * 100 : null} color="linear-gradient(90deg,#1c6dff,#2f8bff)" />}
      >
        <MeasurementValue m={m?.controller_temp_c} unit="°C" />
      </Item>
      <Item
        icon={
          <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-bg-4 text-ink-2">
            <Clock className="h-6 w-6" />
          </div>
        }
        label="Fahrzeit"
        sub={`Gesamt: ${formatHours(t?.vehicle.total_drive_s ?? 0)} h`}
        bar={<Bar value={(((t?.vehicle.trip_s ?? 0) % 3600) / 3600) * 100} color="linear-gradient(90deg,#6d4aff,#8b6cff)" />}
      >
        {formatDuration(t?.vehicle.trip_s ?? 0)} h
      </Item>
      <Item
        icon={
          <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-ok-soft text-ok-2">
            <Leaf className="h-6 w-6" />
          </div>
        }
        label="Modus"
        sub={PROFILE_DESCRIPTION[profile]}
      >
        <span className="text-ok-2">{PROFILE_LABEL[profile]}</span>
      </Item>
      <Item icon={<Wifi className="h-6 w-6" />} label="Signal" sub={<SignalBars level={signalLevel(dbm)} className="text-ink" />}>
        <MeasurementValue m={m?.wifi_signal_dbm} unit="dBm" />
      </Item>
      <Item
        icon={
          blocking.length === 0 && fresh ? <CheckCircle2 className="h-6 w-6 text-ok-2" /> : <XCircle className="h-6 w-6 text-danger" />
        }
        label="System"
        sub={!fresh ? 'Keine Verbindung' : blocking.length === 0 ? 'Keine Fehler' : blocking.map((f) => f.code).join(', ')}
      >
        <span className={blocking.length === 0 && fresh ? 'text-ok-2' : 'text-danger'}>{blocking.length === 0 && fresh ? 'OK' : 'Fehler'}</span>
        <span className="ml-2 text-xs text-ink-3">
          A {front?.link === 'connected' ? '✓' : '✗'} · B {rear?.link === 'connected' ? '✓' : '✗'}
        </span>
      </Item>
    </section>
  );
}
