import { LayoutDashboard, Settings, Wifi, WifiOff } from 'lucide-react';
import { useTelemetryFresh } from '../../hooks/common';
import { navigate } from '../../hooks/useRoute';
import { isCurrent } from '../../lib/format';
import { useVehicle } from '../../stores/vehicleStore';
import { BatteryIcon, Logo } from '../common/Icons';
import { EmergencyStopButton } from './EmergencyStopButton';

export function ConnectionIndicator({ compact = false }: { compact?: boolean }) {
  const conn = useVehicle((s) => s.conn);
  const fresh = useTelemetryFresh();
  let label = 'Getrennt';
  let dot = 'bg-danger shadow-[0_0_10px_#ff3d4a]';
  if (conn === 'open' && fresh) {
    label = 'Verbunden';
    dot = 'bg-ok-2 shadow-[0_0_10px_#22c55e]';
  } else if (conn === 'open') {
    label = 'Instabil';
    dot = 'bg-warn shadow-[0_0_10px_#f6b73c] animate-pulse-soft';
  } else if (conn === 'connecting') {
    label = 'Verbinde …';
    dot = 'bg-warn animate-pulse-soft';
  }
  return (
    <div className="flex items-center gap-2.5" data-testid="connection-indicator" data-state={label}>
      <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${dot}`} />
      <div className="leading-tight">
        <div className="text-[13px] font-medium text-ink sm:text-[15px]">{label}</div>
        {!compact && <div className="hidden text-xs text-ink-3 sm:block">{window.location.hostname}</div>}
      </div>
    </div>
  );
}

export function SimulationBadge() {
  const mode = useVehicle((s) => s.telemetry?.mode ?? s.mode);
  if (mode !== 'simulation') {
    if (mode === 'hardware')
      return (
        <span className="rounded-md border border-ok/60 px-2 py-0.5 text-[11px] font-bold uppercase tracking-[0.14em] text-ok">
          Hardware
        </span>
      );
    return null;
  }
  return (
    <span
      className="rounded-md bg-warn px-2 py-0.5 text-[11px] font-extrabold uppercase tracking-[0.16em] text-bg-0 shadow-[0_0_16px_rgba(246,183,60,0.35)]"
      data-testid="simulation-badge"
      title="Simulationsmodus: Es werden keine realen Motorbefehle gesendet"
    >
      <span className="sm:hidden">Sim</span>
      <span className="hidden sm:inline">Simulation</span>
    </span>
  );
}

export function Header({ showDashboardLink = false }: { showDashboardLink?: boolean }) {
  const battery = useVehicle((s) => s.telemetry?.measurements.battery_percent);
  const quality = useVehicle((s) => s.telemetry?.measurements.wifi_quality);
  const fresh = useTelemetryFresh();
  const batteryValue = isCurrent(battery, fresh) ? Math.round(battery!.value as number) : null;
  return (
    <header className="app-header safe-top flex shrink-0 items-center gap-2 border-b border-line/80 bg-bg-0/80 px-3 backdrop-blur sm:gap-5 sm:px-6">
      <button type="button" onClick={() => navigate('fahren')} className="flex items-center gap-2.5" aria-label="Zur Fahransicht">
        <Logo size={26} />
        <span className="hidden whitespace-nowrap text-[22px] font-semibold tracking-tight text-ink lg:inline">
          AllWheel Control
        </span>
      </button>
      <div className="hidden h-8 w-px bg-line lg:block" />
      <ConnectionIndicator />
      <SimulationBadge />
      <div className="flex-1" />
      <div className="hidden items-center gap-1 text-ink-2 sm:flex" title={`WLAN: ${quality ?? 'unbekannt'}`}>
        {fresh ? <Wifi className="h-5 w-5" /> : <WifiOff className="h-5 w-5 text-danger" />}
      </div>
      <div className="flex items-center gap-2 text-ink-2" title="Akkustand (geschätzt aus Spannung)">
        <BatteryIcon percent={batteryValue} />
        <span className="hidden w-10 text-sm tabular-nums text-ink sm:inline">{batteryValue === null ? '—' : `${batteryValue}%`}</span>
      </div>
      {showDashboardLink && (
        <button
          type="button"
          onClick={() => navigate('dashboard')}
          className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-line text-ink-2 hover:text-ink"
          aria-label="Übersicht"
          title="Übersicht"
        >
          <LayoutDashboard className="h-5 w-5" />
        </button>
      )}
      <EmergencyStopButton />
      <button
        type="button"
        onClick={() => navigate('einstellungen')}
        className="flex h-10 w-9 shrink-0 items-center justify-center rounded-xl text-ink-2 hover:text-ink"
        aria-label="Einstellungen"
      >
        <Settings className="h-6 w-6" />
      </button>
    </header>
  );
}
