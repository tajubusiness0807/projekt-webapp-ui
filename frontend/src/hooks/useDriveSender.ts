// Sendet die Fahreranforderung mit 20 Hz – auch im Leerlauf als Lebenszeichen.
//
// Sicherheitsmaßnahmen im Browser:
// * Werte stammen aus den Totmann-Kanälen (Lease); ohne Erneuerung gehen sie automatisch auf 0.
// * Seite verborgen, Fenster verliert Fokus, Seitenwechsel → alle Eingaben sofort 0.
// * Unbehandelte JavaScript-Fehler → alle Eingaben 0 und Hinweis.
// * Das Profil im Befehl ist das vom Backend bestätigte, nie ein lokal vermutetes.

import { useEffect } from 'react';
import { socket } from '../services/wsClient';
import { readInputs, releaseAllInputs } from '../stores/inputStore';
import { toast } from '../stores/toastStore';
import { useVehicle } from '../stores/vehicleStore';

export const SEND_INTERVAL_MS = 50;

function sendNow(neutral = false): void {
  const telemetry = useVehicle.getState().telemetry;
  if (!telemetry || !telemetry.session.is_owner || !socket.isOpen) return;
  const inputs = neutral ? { throttle: 0, brake: 0, steer: 0, source: 'none' as const } : readInputs();
  socket.send('drive', {
    throttle: inputs.throttle,
    brake: inputs.brake,
    steer: inputs.steer,
    profile: telemetry.vehicle.profile,
    source: inputs.source,
  });
}

export function useDriveSender(): void {
  useEffect(() => {
    const timer = window.setInterval(() => sendNow(), SEND_INTERVAL_MS);

    const neutralize = () => {
      releaseAllInputs();
      sendNow(true);
    };
    const onVisibility = () => {
      if (document.visibilityState !== 'visible') neutralize();
    };
    const onError = () => {
      neutralize();
      toast.error('Interner Fehler in der Oberfläche – alle Eingaben wurden auf 0 gesetzt');
    };

    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('blur', neutralize);
    window.addEventListener('pagehide', neutralize);
    window.addEventListener('error', onError);
    window.addEventListener('unhandledrejection', onError);
    return () => {
      window.clearInterval(timer);
      neutralize();
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('blur', neutralize);
      window.removeEventListener('pagehide', neutralize);
      window.removeEventListener('error', onError);
      window.removeEventListener('unhandledrejection', onError);
    };
  }, []);
}
