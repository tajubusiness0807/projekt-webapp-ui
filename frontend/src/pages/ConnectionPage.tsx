// Verbindung: eigene Sitzung, Steuerungsbesitz, WLAN und Kommunikationsstatus beider Motorcontroller.

import { Hand, LogOut, Shield } from 'lucide-react';
import { MeasurementValue } from '../components/common/MeasurementValue';
import { Badge, Button, Card, Notice, Row } from '../components/common/ui';
import { useIsOwner, useTelemetryFresh } from '../hooks/common';
import { formatNumber } from '../lib/format';
import { command } from '../services/wsClient';
import { deviceLabel } from '../services/storage';
import { useVehicle } from '../stores/vehicleStore';
import type { ControllerTelemetry } from '../types/protocol';

const LINK_LABEL: Record<ControllerTelemetry['link'], { text: string; tone: 'ok' | 'warn' | 'danger' | 'neutral' }> = {
  connected: { text: 'verbunden', tone: 'ok' },
  connecting: { text: 'verbinde …', tone: 'warn' },
  disconnected: { text: 'getrennt', tone: 'danger' },
  error: { text: 'Fehler', tone: 'danger' },
  disabled: { text: 'deaktiviert', tone: 'neutral' },
};

function ControllerCard({ c }: { c: ControllerTelemetry }) {
  const link = LINK_LABEL[c.link];
  const total = c.frames_ok + c.frames_bad;
  return (
    <Card
      title={`Controller ${c.id} · ${c.axle === 'front' ? 'Vorderachse' : 'Hinterachse'}`}
      action={<Badge tone={link.tone}>{link.text}</Badge>}
    >
      <Row label="Adapter">{c.adapter === 'simulation' ? 'Simulation' : 'FOC USART'}</Row>
      <Row label="Schnittstelle">{c.port || '—'}</Row>
      <Row label="Letzte Rückmeldung">{c.feedback_age_ms === null ? 'nie' : `vor ${formatNumber(c.feedback_age_ms)} ms`}</Row>
      <Row label="Pakete gültig / fehlerhaft">
        <span className="tabular-nums">
          {formatNumber(c.frames_ok)} / <span className={c.frames_bad > 0 ? 'text-warn' : ''}>{formatNumber(c.frames_bad)}</span>
          {total > 0 && <span className="text-ink-3"> ({formatNumber((c.frames_bad / total) * 100, 1)} %)</span>}
        </span>
      </Row>
      <Row label="Gesendete Befehle / Schreibfehler">
        <span className="tabular-nums">
          {formatNumber(c.commands_sent)} / {formatNumber(c.write_errors)}
        </span>
      </Row>
      <Row label="Drehzahl links / rechts">
        <MeasurementValue m={c.rpm_left} showTag={false} /> / <MeasurementValue m={c.rpm_right} />
      </Row>
      <Row label="Spannung">
        <MeasurementValue m={c.voltage} digits={2} />
      </Row>
      <Row label="Controller-Temperatur">
        <MeasurementValue m={c.controller_temp_c} digits={1} />
      </Row>
      {c.emergency_stopped && <Notice kind="danger">Not-Aus-Nullbefehl gesendet</Notice>}
      {c.last_error && <p className="mt-2 text-xs text-danger">{c.last_error}</p>}
    </Card>
  );
}

export function ConnectionPage() {
  const t = useVehicle((s) => s.telemetry);
  const conn = useVehicle((s) => s.conn);
  const rtt = useVehicle((s) => s.rttMs);
  const sessionId = useVehicle((s) => s.sessionId);
  const role = useVehicle((s) => s.role);
  const rejected = useVehicle((s) => s.rejectedDrive);
  const fresh = useTelemetryFresh();
  const owner = useIsOwner();
  const session = t?.session;
  const secure = window.location.protocol === 'https:';

  return (
    <div className="page-grid">
      <Card title="Diese Verbindung">
        <Row label="Status">{conn === 'open' && fresh ? <Badge tone="ok">verbunden</Badge> : <Badge tone="danger">{conn}</Badge>}</Row>
        <Row label="Gerät">{deviceLabel()}</Row>
        <Row label="Adresse">{window.location.host}</Row>
        <Row label="Verschlüsselung" hint={secure ? undefined : 'Neigungssteuerung benötigt HTTPS'}>
          {secure ? <Badge tone="ok">HTTPS / WSS</Badge> : <Badge tone="warn">HTTP / WS</Badge>}
        </Row>
        <Row label="Latenz (Hin und zurück)">{rtt === null ? '—' : `${formatNumber(rtt)} ms`}</Row>
        <Row label="Sitzung / Rolle">
          <span className="font-mono text-xs">{sessionId ?? '—'}</span> · {role === 'admin' ? 'Administrator' : 'Fahrer'}
        </Row>
        <Row label="Abgelehnte Fahrbefehle">{formatNumber(rejected)}</Row>
      </Card>

      <Card title="Steuerung" action={<Shield className="h-5 w-5 text-ink-3" />}>
        <Row label="Steuerndes Gerät">{session?.owner_present ? (owner ? 'Dieses Gerät' : session.owner_device) : 'keines'}</Row>
        <Row label="Verbundene Geräte">{session?.count ?? '—'}</Row>
        <div className="mt-3 flex flex-wrap gap-2">
          {owner ? (
            <Button onClick={() => command('release_control', {}, 'Steuerung abgegeben')}>
              <LogOut className="h-4 w-4" /> Steuerung abgeben
            </Button>
          ) : (
            <Button
              tone="primary"
              disabled={!!session?.owner_present && !session.can_takeover}
              onClick={() => command(session?.owner_present ? 'takeover_control' : 'claim_control', {}, 'Dieses Gerät steuert jetzt')}
            >
              <Hand className="h-4 w-4" /> {session?.owner_present ? 'Steuerung übernehmen' : 'Steuerung beanspruchen'}
            </Button>
          )}
        </div>
        <p className="mt-3 text-xs leading-relaxed text-ink-3">
          Es steuert immer genau ein Gerät. Eine Übernahme ist nur im Stillstand möglich und sperrt die Motoren. Not-Aus kann jedes
          angemeldete Gerät auslösen.
        </p>
      </Card>

      <Card title="WLAN">
        <Row label="Signalstärke">
          <MeasurementValue m={t?.measurements.wifi_signal_dbm} />
        </Row>
        <Row label="Qualität">{fresh ? (t?.measurements.wifi_quality ?? '—') : '—'}</Row>
        <p className="mt-2 text-xs text-ink-3">
          Im Access-Point-Modus misst der Raspberry Pi den Empfang dieses Geräts. Bei schwachem Signal stoppt das Fahrzeug über
          den Watchdog, sobald Befehle ausbleiben.
        </p>
      </Card>

      <Card title="Backend">
        <Row label="Regelschleife">{t?.system.loop_hz ? `${formatNumber(t.system.loop_hz, 1)} Hz` : '—'}</Row>
        <Row label="Längster Zyklus">{t?.system.loop_max_ms ? `${formatNumber(t.system.loop_max_ms, 0)} ms` : '—'}</Row>
        <Row label="Betriebsart">{t?.mode === 'hardware' ? 'Hardware' : 'Simulation'}</Row>
      </Card>

      {t?.controllers.map((c) => <ControllerCard key={c.id} c={c} />)}
      {t && t.controllers.length === 0 && (
        <div className="lg:col-span-2">
          <Notice kind="danger">Kein Antrieb initialisiert – siehe Systemansicht (Hardware-Checkliste).</Notice>
        </div>
      )}
    </div>
  );
}
