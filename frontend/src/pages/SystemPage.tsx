// System: Betriebsart, Hardware-Freigabe-Checkliste, Raspberry-Pi-Zustand, Simulationsfehler.

import { CheckCircle2, CircleDashed, FlaskConical, XCircle } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Badge, Card, Notice, Row, Toggle } from '../components/common/ui';
import { useIsOwner } from '../hooks/common';
import { formatNumber } from '../lib/format';
import { api } from '../services/api';
import { command } from '../services/wsClient';
import { useAuth } from '../stores/authStore';
import { useVehicle } from '../stores/vehicleStore';

export function SystemPage() {
  const t = useVehicle((s) => s.telemetry);
  const caps = useVehicle((s) => s.capabilities);
  const version = useVehicle((s) => s.version);
  const token = useAuth((s) => s.token);
  const owner = useIsOwner();
  const [info, setInfo] = useState<Record<string, unknown> | null>(null);

  useEffect(() => {
    if (!token) return;
    let alive = true;
    const load = () =>
      api
        .system(token)
        .then((r) => alive && setInfo(r.system))
        .catch(() => undefined);
    void load();
    const id = window.setInterval(load, 5000);
    return () => {
      alive = false;
      window.clearInterval(id);
    };
  }, [token]);

  const mode = caps?.mode ?? t?.mode;
  const readiness = caps?.readiness ?? [];
  const sys = info as {
    model?: string;
    platform?: string;
    python?: string;
    cpu_temp_c?: number | null;
    load_avg?: number[];
    mem_total_mb?: number | null;
    mem_available_mb?: number | null;
    process_rss_mb?: number | null;
    throttled?: string[] | null;
    uptime_s?: number;
  } | null;

  return (
    <div className="page-grid">
      <Card title="Betriebsart" action={mode === 'simulation' ? <Badge tone="warn">Simulation</Badge> : <Badge tone="ok">Hardware</Badge>}>
        {mode === 'simulation' ? (
          <Notice kind="warning">
            Simulationsmodus: Alle Fahrzeugwerte sind simuliert und als solche gekennzeichnet. Es werden keine realen Motorbefehle gesendet.
          </Notice>
        ) : (
          <Notice kind="ok">Hardwaremodus: Befehle gehen an die realen Motorcontroller. Hardware-Not-Aus griffbereit halten.</Notice>
        )}
        {caps?.hardware_init_error && (
          <div className="mt-3">
            <Notice kind="danger">{caps.hardware_init_error}</Notice>
          </div>
        )}
        {caps?.restart_required && (
          <div className="mt-3">
            <Notice kind="warning">Geänderte Hardware-Einstellungen werden erst nach Neustart des Dienstes wirksam.</Notice>
          </div>
        )}
        {caps?.commissioning && (
          <div className="mt-3">
            <Notice kind="warning">Inbetriebnahme-Modus: max. 15 % Gas und 3 km/h bis der Test mit aufgebockten Rädern bestätigt ist.</Notice>
          </div>
        )}
        <Row label="Software-Version">{version ?? '—'}</Row>
        <Row label="Bremsfunktion">{caps?.brake.note ?? '—'}</Row>
        <Row label="Raddurchmesser">{caps?.wheel_diameter_m ? `${formatNumber(caps.wheel_diameter_m * 1000)} mm` : '—'}</Row>
      </Card>

      <Card title="Hardware-Freigabe-Checkliste">
        <p className="mb-2 text-sm text-ink-2">Der Hardwaremodus startet nur, wenn alle Punkte erfüllt sind (siehe docs/hardware.md).</p>
        <ul className="divide-y divide-line/60">
          {readiness.map((item) => (
            <li key={item.key} className="flex items-start gap-2.5 py-2 text-sm">
              {item.ok ? <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-ok" /> : <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-ink-3" />}
              <span className={item.ok ? 'text-ink' : 'text-ink-2'}>
                {item.label}
                {item.detail && <span className="block text-xs text-ink-3">{item.detail}</span>}
              </span>
            </li>
          ))}
        </ul>
      </Card>

      <Card title="Raspberry Pi">
        <Row label="Modell">{sys?.model ?? '—'}</Row>
        <Row label="System">{sys?.platform ?? '—'}</Row>
        <Row label="Python">{sys?.python ?? '—'}</Row>
        <Row label="CPU-Temperatur">{sys?.cpu_temp_c != null ? `${formatNumber(sys.cpu_temp_c, 1)} °C` : 'nicht verfügbar'}</Row>
        <Row label="Last (1/5/15 min)">{sys?.load_avg ? sys.load_avg.map((v) => formatNumber(v, 2)).join(' / ') : '—'}</Row>
        <Row label="Speicher frei">
          {sys?.mem_available_mb != null ? `${formatNumber(sys.mem_available_mb)} von ${formatNumber(sys.mem_total_mb ?? 0)} MB` : '—'}
        </Row>
        <Row label="Speicher Backend">{sys?.process_rss_mb != null ? `${formatNumber(sys.process_rss_mb)} MB` : '—'}</Row>
        <Row label="Spannungsversorgung" hint="Unterspannung führt zu Hängern – DC/DC-Wandler prüfen">
          {sys?.throttled == null ? (
            'nicht verfügbar'
          ) : sys.throttled.length === 0 ? (
            <Badge tone="ok">in Ordnung</Badge>
          ) : (
            <span className="text-warn">{sys.throttled.join(', ')}</span>
          )}
        </Row>
        <Row label="Regelschleife">{t?.system.loop_hz ? `${formatNumber(t.system.loop_hz, 1)} Hz (max. ${formatNumber(t.system.loop_max_ms ?? 0)} ms)` : '—'}</Row>
        <Row label="Betriebszeit">{sys?.uptime_s != null ? `${formatNumber(sys.uptime_s / 3600, 1)} h` : '—'}</Row>
      </Card>

      {mode === 'simulation' && caps && (
        <Card
          title={
            <span className="flex items-center gap-2">
              <FlaskConical className="h-5 w-5 text-warn" /> Simulationsfehler
            </span>
          }
        >
          <p className="mb-2 text-sm text-ink-2">Fehler gezielt auslösen, um Sicherheitsreaktionen und Anzeigen zu prüfen.</p>
          {Object.entries(caps.simulation_faults).map(([key, label]) => (
            <Row key={key} label={label}>
              <Toggle
                label={label}
                checked={t?.vehicle.sim_faults.includes(key) ?? false}
                disabled={!owner}
                onChange={(v) => command('sim_inject', { fault: key, active: v })}
              />
            </Row>
          ))}
          {!owner && (
            <p className="mt-2 flex items-center gap-1.5 text-xs text-ink-3">
              <CircleDashed className="h-3.5 w-3.5" /> Nur das steuernde Gerät kann Fehler auslösen.
            </p>
          )}
        </Card>
      )}
    </div>
  );
}
