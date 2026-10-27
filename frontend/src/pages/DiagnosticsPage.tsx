// Diagnose: aktive Fehler mit Erklärung und Abhilfe, Ereignisprotokoll, Fehlerkatalog.

import { AlertTriangle, CheckCircle2, Info, OctagonAlert, RefreshCw, Trash2 } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge, Button, Card, Notice, Segmented } from '../components/common/ui';
import { useIsOwner } from '../hooks/common';
import { formatDateTime } from '../lib/format';
import { api } from '../services/api';
import { command } from '../services/wsClient';
import { useAuth } from '../stores/authStore';
import { toast } from '../stores/toastStore';
import { NO_FAULTS, useVehicle } from '../stores/vehicleStore';
import type { EventEntry, Severity } from '../types/protocol';

const LEVEL_ICON = { info: Info, warning: AlertTriangle, critical: OctagonAlert };
const LEVEL_COLOR = { info: 'text-ink-3', warning: 'text-warn', critical: 'text-danger' };

export function DiagnosticsPage() {
  const faults = useVehicle((s) => s.telemetry?.faults ?? NO_FAULTS);
  const catalog = useVehicle((s) => s.faultCatalog);
  const liveEvents = useVehicle((s) => s.events);
  const token = useAuth((s) => s.token);
  const adminToken = useAuth((s) => s.adminToken);
  const owner = useIsOwner();
  const [stored, setStored] = useState<EventEntry[]>([]);
  const [filter, setFilter] = useState<'all' | Severity>('all');

  const load = useCallback(async () => {
    if (!token) return;
    try {
      setStored(await api.events(token, 300));
    } catch (e) {
      toast.error((e as Error).message);
    }
  }, [token]);

  useEffect(() => {
    void load();
  }, [load]);

  const events = useMemo(() => {
    // Live-Ereignisse (seit Verbindungsaufbau) und gespeicherte zusammenführen; nach Zeit sortieren.
    const seen = new Set<string>();
    return [...liveEvents, ...stored]
      .filter((e) => {
        const key = `${e.ts}-${e.code}-${e.message}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      })
      .sort((a, b) => b.ts - a.ts)
      .filter((e) => filter === 'all' || e.level === filter)
      .slice(0, 300);
  }, [liveEvents, stored, filter]);

  return (
    <div className="page-grid">
      <Card
        title="Aktive Fehler und Warnungen"
        className="lg:col-span-2"
        action={
          <Button tone="primary" disabled={!owner || faults.length === 0} onClick={() => command('ack_faults', {}, 'Behobene Fehler quittiert')}>
            Quittieren
          </Button>
        }
      >
        {faults.length === 0 ? (
          <div className="flex items-center gap-2 text-ok">
            <CheckCircle2 className="h-5 w-5" /> Keine Fehler – System OK
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            {faults.map((f) => {
              const def = catalog[f.code];
              const Icon = LEVEL_ICON[f.severity];
              return (
                <div key={`${f.code}-${f.source}`} className="rounded-xl border border-line bg-bg-2 p-3.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <Icon className={`h-5 w-5 ${LEVEL_COLOR[f.severity]}`} />
                    <span className="font-mono text-sm text-ink">{f.code}</span>
                    <strong className="text-ink">{f.title}</strong>
                    {f.blocking && <Badge tone="danger">sperrt Antrieb</Badge>}
                    {f.active ? <Badge tone="warn">Ursache aktiv</Badge> : <Badge tone="ok">behoben – quittieren</Badge>}
                    {f.count > 1 && <Badge>{f.count}×</Badge>}
                    <span className="ml-auto text-xs text-ink-3">{formatDateTime(f.since)}</span>
                  </div>
                  {f.detail && <p className="mt-1.5 text-sm text-ink-2">{f.detail}</p>}
                  {def && (
                    <p className="mt-1.5 text-sm text-ink-3">
                      {def.description} <span className="text-ink-2">Abhilfe: {def.remedy}</span>
                    </p>
                  )}
                </div>
              );
            })}
          </div>
        )}
        {!owner && faults.length > 0 && <p className="mt-3 text-xs text-ink-3">Quittieren kann nur das steuernde Gerät.</p>}
      </Card>

      <Card
        title="Ereignisprotokoll"
        className="lg:col-span-2"
        action={
          <div className="flex items-center gap-2">
            <Segmented
              size="sm"
              value={filter}
              onChange={setFilter}
              options={[
                { value: 'all', label: 'Alle' },
                { value: 'critical', label: 'Kritisch' },
                { value: 'warning', label: 'Warnung' },
                { value: 'info', label: 'Info' },
              ]}
            />
            <Button tone="ghost" onClick={load} title="Aktualisieren">
              <RefreshCw className="h-4 w-4" />
            </Button>
            {adminToken && (
              <Button
                tone="ghost"
                title="Protokoll löschen"
                onClick={async () => {
                  await api.clearEvents(adminToken);
                  useVehicle.setState({ events: [] });
                  await load();
                }}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            )}
          </div>
        }
      >
        <div className="max-h-[480px] overflow-y-auto">
          <table className="w-full text-sm">
            <tbody className="divide-y divide-line/50">
              {events.map((e) => {
                const Icon = LEVEL_ICON[e.level];
                return (
                  <tr key={`${e.ts}-${e.id}-${e.code}`} className="align-top">
                    <td className="whitespace-nowrap py-2 pr-3 text-xs tabular-nums text-ink-3">{formatDateTime(e.ts)}</td>
                    <td className="py-2 pr-2">
                      <Icon className={`h-4 w-4 ${LEVEL_COLOR[e.level]}`} />
                    </td>
                    <td className="whitespace-nowrap py-2 pr-3 font-mono text-xs text-ink-2">{e.code}</td>
                    <td className="py-2 text-ink">
                      {e.message}
                      {e.details && Object.keys(e.details).length > 0 && (
                        <span className="ml-2 text-xs text-ink-3">
                          {Object.entries(e.details)
                            .map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : String(v)}`)
                            .join(' · ')}
                        </span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {events.length === 0 && <p className="py-4 text-sm text-ink-3">Keine Ereignisse.</p>}
        </div>
      </Card>

      <Card title="Fehlercodes" className="lg:col-span-2">
        <Notice>Codes mit E sperren den Antrieb und müssen nach Behebung quittiert werden. W = Warnung, I = Information.</Notice>
        <div className="mt-3 grid gap-2 md:grid-cols-2">
          {Object.values(catalog).map((d) => (
            <div key={d.code} className="rounded-xl border border-line bg-bg-2/60 p-3 text-sm">
              <div className="flex items-center gap-2">
                <span className="font-mono text-ink">{d.code}</span>
                <strong className="text-ink">{d.title}</strong>
              </div>
              <p className="mt-1 text-ink-3">{d.description}</p>
              <p className="mt-1 text-ink-2">Abhilfe: {d.remedy}</p>
            </div>
          ))}
        </div>
      </Card>
    </div>
  );
}
