import { create } from 'zustand';
import type {
  ActiveFault,
  Capabilities,
  EventEntry,
  FaultDefinition,
  Role,
  Telemetry,
  VehicleSettings,
} from '../types/protocol';

export type ConnectionState = 'idle' | 'connecting' | 'open' | 'closed' | 'auth_failed' | 'rejected';

interface VehicleStore {
  conn: ConnectionState;
  connMessage: string | null;
  sessionId: string | null;
  role: Role | null;
  version: string | null;
  mode: 'simulation' | 'hardware' | null;
  settings: VehicleSettings | null;
  settingsVersion: number;
  capabilities: Capabilities | null;
  faultCatalog: Record<string, FaultDefinition>;
  telemetry: Telemetry | null;
  lastTelemetryAt: number;
  rttMs: number | null;
  events: EventEntry[];
  rejectedDrive: number;
}

export const useVehicle = create<VehicleStore>(() => ({
  conn: 'idle',
  connMessage: null,
  sessionId: null,
  role: null,
  version: null,
  mode: null,
  settings: null,
  settingsVersion: 0,
  capabilities: null,
  faultCatalog: {},
  telemetry: null,
  lastTelemetryAt: 0,
  rttMs: null,
  events: [],
  rejectedDrive: 0,
}));

export const TELEMETRY_FRESH_MS = 1500;

/** Stabile leere Liste für Selektoren (neue Arrays je Aufruf würden Endlos-Renderzyklen auslösen). */
export const NO_FAULTS: readonly ActiveFault[] = Object.freeze([]);

export function telemetryFresh(now = performance.now()): boolean {
  const { conn, lastTelemetryAt } = useVehicle.getState();
  return conn === 'open' && now - lastTelemetryAt < TELEMETRY_FRESH_MS;
}
