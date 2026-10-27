import { create } from 'zustand';
import { local, session } from '../services/storage';
import type { Role } from '../types/protocol';

interface AuthState {
  token: string | null;
  role: Role | null;
  adminToken: string | null;
  setDriver(token: string, role: Role): void;
  setAdmin(token: string | null): void;
  logout(): void;
}

// Fahrer-Token bleibt auf dem Gerät gespeichert (Ablauf durch den Server), Admin-Token nur für die Sitzung.
export const useAuth = create<AuthState>((set) => ({
  token: local.get('awc.token'),
  role: (local.get('awc.role') as Role | null) ?? null,
  adminToken: session.get('awc.adminToken'),
  setDriver(token, role) {
    local.set('awc.token', token);
    local.set('awc.role', role);
    set({ token, role });
  },
  setAdmin(token) {
    if (token) session.set('awc.adminToken', token);
    else session.remove('awc.adminToken');
    set({ adminToken: token });
  },
  logout() {
    local.remove('awc.token');
    local.remove('awc.role');
    session.remove('awc.adminToken');
    set({ token: null, role: null, adminToken: null });
  },
}));
