// WebSocket-Verbindung zum Fahrzeug.
//
// * Authentifizierung per „hello“ mit Token (nicht in der URL, damit er in keinem Log landet).
// * Jede Steuernachricht erhält eine fortlaufende Sequenznummer und einen Zeitstempel.
// * Ping alle 2 s misst die Latenz; kommt 2,5 s lang gar nichts an, wird die Verbindung als tot
//   betrachtet, neu aufgebaut und alle Eingaben werden zurückgesetzt.
// * Wiederverbindung mit wachsendem Abstand. Nach Wiederverbindung ist die Steuerung neutral – die
//   Motorfreigabe muss bewusst neu erteilt werden (das Backend sperrt bei Verbindungsverlust).

import { releaseAllInputs } from '../stores/inputStore';
import { toast } from '../stores/toastStore';
import { useVehicle } from '../stores/vehicleStore';
import type { Ack, ServerMessage } from '../types/protocol';
import { clientId, deviceLabel } from './storage';

const PROTOCOL_VERSION = 1;
const PING_INTERVAL_MS = 2000;
const DEAD_AFTER_MS = 2500;
const REQUEST_TIMEOUT_MS = 4000;

type Pending = { resolve: (ack: Ack) => void; timer: number; type: string };

export class VehicleSocket {
  private ws: WebSocket | null = null;
  private token: string | null = null;
  private seq = 0;
  private pending = new Map<number, Pending>();
  private reconnectTimer: number | undefined;
  private pingTimer: number | undefined;
  private attempts = 0;
  private lastMessageAt = 0;
  private lastPingAt = 0;
  private stopped = true;
  onAuthFailed: (() => void) | null = null;

  start(token: string): void {
    this.token = token;
    this.stopped = false;
    this.open();
  }

  stop(): void {
    this.stopped = true;
    window.clearTimeout(this.reconnectTimer);
    window.clearInterval(this.pingTimer);
    this.ws?.close(1000, 'Abmeldung');
    this.ws = null;
    useVehicle.setState({ conn: 'idle' });
  }

  get isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN && useVehicle.getState().sessionId !== null;
  }

  /** Sendet eine Steuernachricht. Gibt die Sequenznummer zurück oder null, wenn nicht verbunden. */
  send(type: string, fields: Record<string, unknown> = {}): number | null {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return null;
    const seq = ++this.seq;
    this.ws.send(JSON.stringify({ type, seq, ts: Date.now(), ...fields }));
    return seq;
  }

  /** Sendet und wartet auf die Bestätigung des Servers. */
  request(type: string, fields: Record<string, unknown> = {}): Promise<Ack> {
    return new Promise((resolve) => {
      const seq = this.send(type, fields);
      if (seq === null) {
        resolve({ type: 'ack', ref_type: type, ref_seq: null, ok: false, code: 'OFFLINE', message: 'Keine Verbindung zum Fahrzeug' });
        return;
      }
      const timer = window.setTimeout(() => {
        this.pending.delete(seq);
        resolve({ type: 'ack', ref_type: type, ref_seq: seq, ok: false, code: 'TIMEOUT', message: 'Keine Antwort vom Fahrzeug' });
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(seq, { resolve, timer, type });
    });
  }

  private url(): string {
    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
    return `${proto}://${window.location.host}/ws`;
  }

  private open(): void {
    if (this.stopped || !this.token) return;
    window.clearTimeout(this.reconnectTimer);
    useVehicle.setState({ conn: 'connecting' });
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url());
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    this.seq = 0;
    ws.onopen = () => {
      this.lastMessageAt = performance.now();
      ws.send(
        JSON.stringify({
          type: 'hello',
          protocol: PROTOCOL_VERSION,
          token: this.token,
          client_id: clientId(),
          device: deviceLabel(),
          ts: Date.now(),
        }),
      );
      window.clearInterval(this.pingTimer);
      this.pingTimer = window.setInterval(() => this.tick(), PING_INTERVAL_MS / 4);
    };
    ws.onmessage = (event) => {
      this.lastMessageAt = performance.now();
      let msg: ServerMessage;
      try {
        msg = JSON.parse(String(event.data)) as ServerMessage;
      } catch {
        return;
      }
      this.handle(msg);
    };
    ws.onclose = (event) => {
      if (this.ws !== ws) return;
      this.ws = null;
      window.clearInterval(this.pingTimer);
      releaseAllInputs();
      this.failPending();
      useVehicle.setState({ sessionId: null });
      if (event.code === 4001) {
        useVehicle.setState({ conn: 'auth_failed', connMessage: 'Anmeldung abgelaufen – bitte erneut anmelden' });
        this.stopped = true;
        this.onAuthFailed?.();
        return;
      }
      if (event.code === 4003) {
        useVehicle.setState({ conn: 'rejected', connMessage: 'Zu viele verbundene Geräte' });
      } else if (event.code === 4004) {
        useVehicle.setState({ conn: 'rejected', connMessage: 'Verbindung aus dieser Herkunft nicht erlaubt' });
      } else {
        useVehicle.setState({ conn: 'closed' });
      }
      this.scheduleReconnect();
    };
  }

  private tick(): void {
    const now = performance.now();
    if (now - this.lastMessageAt > DEAD_AFTER_MS && this.ws) {
      // Keine Telemetrie mehr: Verbindung als tot behandeln (z. B. halboffene TCP-Verbindung).
      releaseAllInputs();
      this.ws.close(4000, 'Zeitüberschreitung');
      return;
    }
    if (this.ws?.readyState === WebSocket.OPEN && now - this.lastPingAt >= PING_INTERVAL_MS) {
      this.lastPingAt = now;
      this.ws.send(JSON.stringify({ type: 'ping', ts: Date.now(), rtt_ms: useVehicle.getState().rttMs }));
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    this.attempts += 1;
    const delay = Math.min(5000, 400 * 2 ** Math.min(this.attempts, 4));
    this.reconnectTimer = window.setTimeout(() => this.open(), delay);
  }

  private failPending(): void {
    for (const [seq, p] of this.pending) {
      window.clearTimeout(p.timer);
      p.resolve({ type: 'ack', ref_type: p.type, ref_seq: seq, ok: false, code: 'OFFLINE', message: 'Verbindung unterbrochen' });
    }
    this.pending.clear();
  }

  private handle(msg: ServerMessage): void {
    switch (msg.type) {
      case 'welcome': {
        this.attempts = 0;
        const catalog = Object.fromEntries(msg.fault_catalog.map((f) => [f.code, f]));
        useVehicle.setState({
          conn: 'open',
          connMessage: null,
          sessionId: msg.session_id,
          role: msg.role,
          version: msg.version,
          mode: msg.mode,
          settings: msg.settings,
          settingsVersion: msg.settings_version,
          capabilities: msg.capabilities,
          faultCatalog: catalog,
          events: msg.events,
        });
        break;
      }
      case 'telemetry':
        useVehicle.setState({ telemetry: msg, lastTelemetryAt: performance.now(), conn: 'open' });
        break;
      case 'pong':
        useVehicle.setState({ rttMs: Math.max(0, Date.now() - msg.ts) });
        break;
      case 'ack': {
        const pending = msg.ref_seq !== null ? this.pending.get(msg.ref_seq) : undefined;
        if (pending) {
          window.clearTimeout(pending.timer);
          this.pending.delete(msg.ref_seq as number);
          pending.resolve(msg);
        } else if (!msg.ok) {
          if (msg.ref_type === 'drive') {
            useVehicle.setState((s) => ({ rejectedDrive: s.rejectedDrive + 1 }));
          } else if (msg.message) {
            toast.error(msg.message);
          }
        }
        break;
      }
      case 'event':
        useVehicle.setState((s) => ({ events: [msg.event, ...s.events].slice(0, 200) }));
        break;
      case 'settings':
        useVehicle.setState({ settings: msg.settings, settingsVersion: msg.version, capabilities: msg.capabilities });
        break;
      case 'connection':
        releaseAllInputs();
        toast.warning(msg.message);
        break;
      case 'error':
        useVehicle.setState({ connMessage: msg.message });
        break;
    }
  }
}

export const socket = new VehicleSocket();

/** Sendet eine Anfrage und zeigt Fehler als Hinweis an. Gibt true bei Erfolg zurück. */
export async function command(type: string, fields: Record<string, unknown> = {}, successMessage?: string): Promise<boolean> {
  const ack = await socket.request(type, fields);
  if (!ack.ok) {
    const details = ack.details?.map((d) => `${d.loc}: ${d.msg}`).join('; ');
    toast.error([ack.message ?? 'Befehl abgelehnt', details].filter(Boolean).join(' – '));
    return false;
  }
  if (successMessage) toast.success(successMessage);
  return true;
}
