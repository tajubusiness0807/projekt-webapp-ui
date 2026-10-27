// Minimaler Hash-Router (keine zusätzliche Abhängigkeit; funktioniert ohne Server-Rewrites).
// Adressen: #fahren, #dashboard, … (die ältere Form #/fahren wird ebenfalls erkannt).

import { useSyncExternalStore } from 'react';

export type RouteName =
  | 'fahren'
  | 'dashboard'
  | 'fahrmodi'
  | 'leistung'
  | 'einstellungen'
  | 'verbindung'
  | 'diagnose'
  | 'system';

export const ROUTES: RouteName[] = ['fahren', 'dashboard', 'fahrmodi', 'leistung', 'einstellungen', 'verbindung', 'diagnose', 'system'];

function current(): RouteName {
  const hash = window.location.hash.replace(/^#\/?/, '').split('?')[0] as RouteName;
  return ROUTES.includes(hash) ? hash : 'fahren';
}

function subscribe(cb: () => void): () => void {
  window.addEventListener('hashchange', cb);
  return () => window.removeEventListener('hashchange', cb);
}

export function useRoute(): RouteName {
  return useSyncExternalStore(subscribe, current);
}

export function navigate(route: RouteName): void {
  if (current() !== route) window.location.hash = route;
}
