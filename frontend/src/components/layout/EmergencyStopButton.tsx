// Software-Not-Aus: ein Tipp genügt, jede angemeldete Sitzung darf ihn auslösen.
// Ersetzt keinen unabhängigen Hardware-Not-Aus (siehe docs/safety.md).

import { OctagonX } from 'lucide-react';
import { socket } from '../../services/wsClient';
import { releaseAllInputs } from '../../stores/inputStore';
import { toast } from '../../stores/toastStore';
import { useVehicle } from '../../stores/vehicleStore';

export function EmergencyStopButton({ large = false }: { large?: boolean }) {
  const active = useVehicle((s) => s.telemetry?.vehicle.estop ?? false);
  const trigger = async () => {
    releaseAllInputs();
    const ack = await socket.request('estop', { reason: 'Not-Aus-Taste' });
    if (!ack.ok) toast.error(`Not-Aus nicht bestätigt: ${ack.message ?? 'keine Verbindung'} – Hardware-Not-Aus benutzen!`);
  };
  return (
    <button
      type="button"
      onClick={trigger}
      data-testid="estop"
      className={`flex shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-xl border-2 font-bold uppercase tracking-wide text-white transition ${
        active ? 'animate-pulse-soft border-danger bg-danger' : 'border-danger bg-danger-2/90 hover:bg-danger'
      } ${large ? 'h-14 px-6 text-base' : 'h-10 px-2.5 text-xs sm:px-3'} shadow-glow-danger`}
      aria-label="Not-Aus"
      title="Software-Not-Aus – ersetzt keinen Hardware-Not-Aus"
    >
      <OctagonX className={large ? 'h-6 w-6' : 'h-5 w-5'} />
      <span className="hidden sm:inline">{active ? 'Not-Aus aktiv' : 'Not-Aus'}</span>
    </button>
  );
}
