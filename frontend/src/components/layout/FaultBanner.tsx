import { AlertTriangle, ChevronRight, Info, OctagonAlert } from 'lucide-react';
import { useTelemetryFresh } from '../../hooks/common';
import { navigate } from '../../hooks/useRoute';
import { NO_FAULTS, useVehicle } from '../../stores/vehicleStore';

/** Zeigt den wichtigsten aktiven Fehler bzw. die wichtigste Warnung an. */
export function FaultBanner() {
  const faults = useVehicle((s) => s.telemetry?.faults ?? NO_FAULTS);
  const catalog = useVehicle((s) => s.faultCatalog);
  const conn = useVehicle((s) => s.conn);
  const connMessage = useVehicle((s) => s.connMessage);
  const fresh = useTelemetryFresh();

  if (!fresh && conn !== 'idle') {
    return (
      <div className="flex items-center gap-3 border-b border-danger/40 bg-danger-soft/80 px-4 py-2 text-sm text-[#ffb3b8]" role="alert">
        <OctagonAlert className="h-5 w-5 shrink-0" />
        <span>
          <strong>Keine Verbindung zum Fahrzeug.</strong> Alle Anzeigen sind veraltet, Bedienelemente gesperrt.{' '}
          {connMessage ?? 'Das Backend stoppt das Fahrzeug selbsttätig.'}
        </span>
      </div>
    );
  }

  const shown = faults.filter((f) => f.code !== 'W013');
  if (shown.length === 0) return null;
  const top = shown[0];
  const critical = top.severity === 'critical';
  const warning = top.severity === 'warning';
  const Icon = critical ? OctagonAlert : warning ? AlertTriangle : Info;
  const style = critical
    ? 'border-danger/40 bg-danger-soft/80 text-[#ffc2c6]'
    : warning
      ? 'border-warn/40 bg-warn-soft/70 text-warn'
      : 'border-accent/30 bg-accent-soft/40 text-ink-2';
  const remedy = catalog[top.code]?.remedy;
  return (
    <button
      type="button"
      onClick={() => navigate('diagnose')}
      className={`flex w-full items-center gap-3 border-b px-4 py-2 text-left text-sm ${style}`}
      role="alert"
      data-testid="fault-banner"
    >
      <Icon className="h-5 w-5 shrink-0" />
      <span className="min-w-0 flex-1 truncate">
        <strong className="mr-1.5 font-mono">{top.code}</strong>
        <strong>{top.title}</strong>
        {top.detail && <span className="opacity-80"> – {top.detail}</span>}
        {remedy && <span className="hidden opacity-70 lg:inline"> · {remedy}</span>}
        {!top.active && top.blocking && <span className="opacity-80"> · behoben, bitte quittieren</span>}
      </span>
      {shown.length > 1 && <span className="shrink-0 rounded bg-black/30 px-1.5 text-xs">+{shown.length - 1}</span>}
      <ChevronRight className="h-4 w-4 shrink-0 opacity-70" />
    </button>
  );
}
