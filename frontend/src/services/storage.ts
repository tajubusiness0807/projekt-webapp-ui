// Kleine, fehlertolerante Hülle um localStorage/sessionStorage (z. B. privater Modus, gesperrter Speicher).

function safe<T>(fn: () => T, fallback: T): T {
  try {
    return fn();
  } catch {
    return fallback;
  }
}

export const local = {
  get(key: string): string | null {
    return safe(() => window.localStorage.getItem(key), null);
  },
  set(key: string, value: string): void {
    safe(() => window.localStorage.setItem(key, value), undefined);
  },
  remove(key: string): void {
    safe(() => window.localStorage.removeItem(key), undefined);
  },
  getJson<T>(key: string, fallback: T): T {
    const raw = local.get(key);
    if (!raw) return fallback;
    return safe(() => JSON.parse(raw) as T, fallback);
  },
  setJson(key: string, value: unknown): void {
    local.set(key, JSON.stringify(value));
  },
};

export const session = {
  get(key: string): string | null {
    return safe(() => window.sessionStorage.getItem(key), null);
  },
  set(key: string, value: string): void {
    safe(() => window.sessionStorage.setItem(key, value), undefined);
  },
  remove(key: string): void {
    safe(() => window.sessionStorage.removeItem(key), undefined);
  },
};

/** Dauerhafte, zufällige Geräte-ID (für die Wiedererkennung nach Verbindungsabbruch). */
export function clientId(): string {
  let id = local.get('awc.clientId');
  if (!id || !/^[A-Za-z0-9_-]{4,64}$/.test(id)) {
    const bytes = new Uint8Array(12);
    crypto.getRandomValues(bytes);
    id = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    local.set('awc.clientId', id);
  }
  return id;
}

export function deviceLabel(): string {
  const ua = navigator.userAgent;
  const touch = navigator.maxTouchPoints > 0;
  const minSide = Math.min(window.screen.width, window.screen.height);
  let kind = 'Computer';
  if (/iPad/.test(ua) || (touch && /Macintosh/.test(ua))) kind = 'Tablet';
  else if (/Android|iPhone|Mobile/.test(ua)) kind = minSide >= 600 ? 'Tablet' : 'Smartphone';
  const suffix = clientId().slice(0, 4).toUpperCase();
  return `${kind} ${suffix}`;
}
