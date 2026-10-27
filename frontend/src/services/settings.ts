// Änderungen an Einstellungen.
// Fahrer-Abschnitte laufen über den WebSocket (nur Steuerungsbesitzer), Admin-Abschnitte über REST
// mit Administrator-Token. Das Backend validiert in beiden Fällen und begrenzt zur Laufzeit erneut.

import { useAuth } from '../stores/authStore';
import { toast } from '../stores/toastStore';
import { api, ApiError } from './api';
import { command } from './wsClient';

export function updateDriverSettings(patch: Record<string, unknown>, success?: string): Promise<boolean> {
  return command('update_settings', { patch }, success);
}

export async function updateAdminSettings(patch: Record<string, unknown>, success = 'Gespeichert'): Promise<boolean> {
  const token = useAuth.getState().adminToken;
  if (!token) {
    toast.warning('Administratorrechte erforderlich – bitte als Administrator anmelden');
    return false;
  }
  try {
    await api.patchSettings(token, patch);
    toast.success(success);
    return true;
  } catch (error) {
    if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
      useAuth.getState().setAdmin(null);
    }
    const details =
      error instanceof ApiError && Array.isArray(error.details)
        ? (error.details as { loc: string; msg: string }[]).map((d) => `${d.loc}: ${d.msg}`).join('; ')
        : '';
    toast.error([(error as Error).message, details].filter(Boolean).join(' – '));
    return false;
  }
}
