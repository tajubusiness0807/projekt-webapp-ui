import { Cable, Cpu, Gauge, LayoutDashboard, SlidersHorizontal, Settings, Stethoscope, Wifi } from 'lucide-react';
import type { ComponentType } from 'react';
import { navigate, useRoute, type RouteName } from '../../hooks/useRoute';
import { useVehicle } from '../../stores/vehicleStore';

interface NavItem {
  route: RouteName;
  label: string;
  short: string;
  icon: ComponentType<{ className?: string }>;
}

export const NAV_ITEMS: NavItem[] = [
  { route: 'fahren', label: 'Fahren', short: 'Fahren', icon: Gauge },
  { route: 'dashboard', label: 'Dashboard', short: 'Übersicht', icon: LayoutDashboard },
  { route: 'fahrmodi', label: 'Fahrmodi', short: 'Modi', icon: SteeringWheel },
  { route: 'leistung', label: 'Leistung', short: 'Leistung', icon: SlidersHorizontal },
  { route: 'einstellungen', label: 'Einstellungen', short: 'Einstell.', icon: Settings },
  { route: 'verbindung', label: 'Verbindung', short: 'Verbind.', icon: Wifi },
  { route: 'diagnose', label: 'Diagnose', short: 'Diagnose', icon: Stethoscope },
  { route: 'system', label: 'System', short: 'System', icon: Cpu },
];

function SteeringWheel({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden>
      <circle cx="12" cy="12" r="9" />
      <circle cx="12" cy="12" r="2.2" />
      <path d="M3.5 10.5c3-1.2 5.5-1.6 8.5-1.6s5.5.4 8.5 1.6M10.3 14 6.4 19.7M13.7 14l3.9 5.7" />
    </svg>
  );
}

function FaultDot() {
  const blocking = useVehicle((s) => s.telemetry?.faults.some((f) => f.blocking) ?? false);
  if (!blocking) return null;
  return <span className="absolute right-3 top-2 h-2 w-2 rounded-full bg-danger shadow-[0_0_8px_#ff3d4a]" />;
}

export function Sidebar() {
  const route = useRoute();
  const version = useVehicle((s) => s.version);
  return (
    <nav className="hidden w-[150px] shrink-0 flex-col border-r border-line/80 bg-bg-1/60 md:flex" aria-label="Hauptnavigation">
      <div className="flex flex-1 flex-col gap-1 pt-4">
        {NAV_ITEMS.map(({ route: r, label, icon: Icon }) => {
          const active = r === route;
          return (
            <button
              key={r}
              type="button"
              onClick={() => navigate(r)}
              className={`relative flex flex-col items-center gap-1.5 px-2 py-3.5 text-[13px] transition ${
                active ? 'bg-gradient-to-r from-accent-soft to-accent-soft/20 text-accent' : 'text-ink-2 hover:text-ink'
              }`}
              aria-current={active ? 'page' : undefined}
            >
              {active && <span className="absolute inset-y-0 left-0 w-1 rounded-r bg-accent shadow-[0_0_10px_#2f8bff]" />}
              <Icon className="h-7 w-7" />
              {label}
              {r === 'diagnose' && <FaultDot />}
            </button>
          );
        })}
      </div>
      <div className="flex items-center gap-1.5 px-4 pb-4 text-xs text-ink-4">
        <Cable className="h-3.5 w-3.5" />v{version ?? '1.0.0'}
      </div>
    </nav>
  );
}

export function BottomNav() {
  const route = useRoute();
  return (
    <nav
      className="safe-bottom flex shrink-0 overflow-x-auto border-t border-line/80 bg-bg-1/95 md:hidden"
      aria-label="Hauptnavigation"
    >
      {NAV_ITEMS.map(({ route: r, short, icon: Icon }) => {
        const active = r === route;
        return (
          <button
            key={r}
            type="button"
            onClick={() => navigate(r)}
            className={`relative flex min-w-[56px] flex-1 flex-col items-center gap-0.5 py-2 text-[10px] ${active ? 'text-accent' : 'text-ink-3'}`}
            aria-current={active ? 'page' : undefined}
          >
            <Icon className="h-5 w-5" />
            {short}
            {r === 'diagnose' && <FaultDot />}
          </button>
        );
      })}
    </nav>
  );
}
