// REST-Zugriffe (Anmeldung, Administration, Diagnose). Fahrbefehle laufen nur über den WebSocket.

import type { EventEntry, ReadinessItem, Role } from '../types/protocol';

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

async function request<T>(path: string, init: RequestInit & { token?: string | null } = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.token) headers.set('Authorization', `Bearer ${init.token}`);
  if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  let response: Response;
  try {
    response = await fetch(path, { ...init, headers, cache: 'no-store' });
  } catch {
    throw new ApiError('Fahrzeug nicht erreichbar – WLAN-Verbindung prüfen', 0);
  }
  if (!response.ok) {
    let message = `Fehler ${response.status}`;
    let details: unknown;
    try {
      const body = await response.json();
      const detail = body?.detail;
      if (typeof detail === 'string') message = detail;
      else if (detail?.message) {
        message = detail.message;
        details = detail.details;
      } else if (Array.isArray(detail)) message = 'Eingabe ungültig';
    } catch {
      /* Antwort ohne JSON */
    }
    if (response.status === 429) {
      const retry = response.headers.get('Retry-After');
      if (retry) message = `${message} (${retry} s)`;
    }
    throw new ApiError(message, response.status, details);
  }
  return (await response.json()) as T;
}

export interface LoginResult {
  token: string;
  role: Role;
  expires_at: number;
}

export const api = {
  login(secret: string, role: Role): Promise<LoginResult> {
    return request('/api/auth/login', { method: 'POST', body: JSON.stringify({ secret, role }) });
  },
  me(token: string): Promise<{ role: Role; expires_at: number }> {
    return request('/api/auth/me', { token });
  },
  health(): Promise<{ status: string; version: string; mode: string; state: string }> {
    return request('/api/health');
  },
  patchSettings(token: string, patch: Record<string, unknown>, expectedVersion?: number): Promise<{ version: number }> {
    return request('/api/settings', {
      method: 'PATCH',
      token,
      body: JSON.stringify({ patch, expected_version: expectedVersion ?? null }),
    });
  },
  resetSettings(token: string): Promise<{ version: number }> {
    return request('/api/settings/reset', { method: 'POST', token });
  },
  events(token: string, limit = 300): Promise<EventEntry[]> {
    return request(`/api/diagnostics/events?limit=${limit}`, { token });
  },
  clearEvents(token: string): Promise<{ ok: boolean }> {
    return request('/api/diagnostics/events', { method: 'DELETE', token });
  },
  settingsHistory(token: string): Promise<{ version: number; created_at: number; source: string }[]> {
    return request('/api/settings/history', { token });
  },
  system(token: string): Promise<{
    version: string;
    mode: string;
    tls: boolean;
    restart_required: boolean;
    hardware_init_error: string | null;
    readiness: ReadinessItem[];
    system: Record<string, unknown>;
  }> {
    return request('/api/system', { token });
  },
};
