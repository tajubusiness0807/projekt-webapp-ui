// Leistungsverteilung: Voreinstellungen, freie Gewichtung, Live-Werte mit klarer Begriffstrennung.

import { useState } from 'react';
import { MeasurementValue } from '../components/common/MeasurementValue';
import { Button, Card, Notice } from '../components/common/ui';
import { PowerSplitControl } from '../components/controls/PowerSplit';
import { SettingSlider } from '../components/controls/SettingSlider';
import { useIsOwner } from '../hooks/common';
import { navigate } from '../hooks/useRoute';
import { formatNumber } from '../lib/format';
import { DRIVE_MODE_LABEL } from '../lib/labels';
import { command } from '../services/wsClient';
import { useVehicle } from '../stores/vehicleStore';

const PRESETS = [
  { front: 100, label: '100 / 0', sub: 'nur vorne' },
  { front: 0, label: '0 / 100', sub: 'nur hinten' },
  { front: 50, label: '50 / 50', sub: 'gleichmäßig' },
];

export function PowerPage() {
  const t = useVehicle((s) => s.telemetry);
  const settings = useVehicle((s) => s.settings);
  const caps = useVehicle((s) => s.capabilities);
  const owner = useIsOwner();
  const [busy, setBusy] = useState(false);
  if (!settings || !caps) return null;

  const available = caps.axle_distribution.available;
  const applyPreset = async (front: number) => {
    setBusy(true);
    const ok = await command('set_power_split', { target: 'custom', front_percent: front });
    if (ok && t?.vehicle.drive_mode !== 'custom') await command('set_drive_mode', { mode: 'custom' });
    setBusy(false);
  };

  const split = t?.control.split;
  const out = t?.control.output;
  const front = t?.controllers.find((c) => c.axle === 'front');
  const rear = t?.controllers.find((c) => c.axle === 'rear');
  const custom = settings.power_split.custom_front_percent;

  return (
    <div className="page-grid">
      <Card title="Leistungsverteilung" className="lg:col-span-2">
        <Notice>
          <strong>Angeforderte Gewichtung</strong> ist die relative Aufteilung der Fahranforderung (vorne + hinten = 100 %). Die
          Achse mit der höheren Gewichtung erhält die volle, bereits begrenzte Anforderung, die andere den Anteil
          <em> klein/groß</em> – 60/40 ergibt vorne 1,00 und hinten 0,67. Das ist <strong>nicht</strong> die aufgenommene
          elektrische Leistung: Diese hängt von Drehzahl, Last, Akkuspannung und Controllerregelung ab und wird nur angezeigt,
          wenn sie gemessen wird.
        </Notice>
        {!available && <div className="mt-3"><Notice kind="warning">Nicht verfügbar: {caps.axle_distribution.reason}</Notice></div>}
        <div className="mt-4 grid gap-6 lg:grid-cols-2">
          <div>
            <h3 className="mb-2 text-sm font-semibold text-ink">Aktiver Modus: {DRIVE_MODE_LABEL[t?.vehicle.drive_mode ?? 'awd']}</h3>
            <PowerSplitControl />
          </div>
          <div>
            <h3 className="mb-2 text-sm font-semibold text-ink">Voreinstellungen (Modus Custom)</h3>
            <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-4">
              {PRESETS.map((p) => (
                <button
                  key={p.label}
                  type="button"
                  disabled={!owner || !available || busy}
                  onClick={() => applyPreset(p.front)}
                  className={`rounded-xl border px-3 py-3 text-center transition disabled:opacity-40 ${
                    t?.vehicle.drive_mode === 'custom' && custom === p.front ? 'border-accent bg-accent-soft/60 shadow-glow-accent' : 'border-line bg-bg-2 hover:border-line-strong'
                  }`}
                >
                  <div className="text-base font-semibold tabular-nums text-ink">{p.label}</div>
                  <div className="text-xs text-ink-3">{p.sub}</div>
                </button>
              ))}
              <button
                type="button"
                disabled={!owner || !available || busy}
                onClick={() => command('set_drive_mode', { mode: 'custom' })}
                className={`rounded-xl border px-3 py-3 text-center transition disabled:opacity-40 ${
                  t?.vehicle.drive_mode === 'custom' && !PRESETS.some((p) => p.front === custom) ? 'border-accent bg-accent-soft/60' : 'border-line bg-bg-2'
                }`}
              >
                <div className="text-base font-semibold text-ink">Frei</div>
                <div className="text-xs text-ink-3">benutzerdefiniert</div>
              </button>
            </div>
            <div className="mt-3 grid gap-x-6">
              <SettingSlider label="Allrad: Anteil vorne" value={settings.power_split.awd_front_percent} min={20} max={80} unit="%" disabled={!owner || !available} hint="Im Allradmodus treiben immer beide Achsen (20–80 %)." onCommit={(v) => command('set_power_split', { target: 'awd', front_percent: v })} />
              <SettingSlider label="Custom: Anteil vorne" value={custom} min={0} max={100} unit="%" disabled={!owner || !available} onCommit={(v) => command('set_power_split', { target: 'custom', front_percent: v })} />
            </div>
          </div>
        </div>
      </Card>

      <Card title="Live-Werte" className="lg:col-span-2">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[520px] text-sm">
            <thead>
              <tr className="text-left text-xs uppercase tracking-wide text-ink-3">
                <th className="py-2 font-medium">Größe</th>
                <th className="py-2 font-medium">Vorderachse</th>
                <th className="py-2 font-medium">Hinterachse</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line/60 tabular-nums text-ink">
              <tr>
                <td className="py-2.5 text-ink-2">Angeforderte Gewichtung</td>
                <td>{split ? `${formatNumber(split.front_weight)} %` : '—'}</td>
                <td>{split ? `${formatNumber(split.rear_weight)} %` : '—'}</td>
              </tr>
              <tr>
                <td className="py-2.5 text-ink-2">Achsfaktor</td>
                <td>{split ? formatNumber(split.front_scale, 2) : '—'}</td>
                <td>{split ? formatNumber(split.rear_scale, 2) : '—'}</td>
              </tr>
              <tr>
                <td className="py-2.5 text-ink-2">Begrenzte Motoranforderung (links / rechts)</td>
                <td>{out ? `${formatNumber(out.front.left * 100)} % / ${formatNumber(out.front.right * 100)} %` : '—'}</td>
                <td>{out ? `${formatNumber(out.rear.left * 100)} % / ${formatNumber(out.rear.right * 100)} %` : '—'}</td>
              </tr>
              <tr>
                <td className="py-2.5 text-ink-2">Gemessene elektrische Leistung</td>
                <td>
                  <MeasurementValue m={front?.electrical_power_w} unit="W" />
                </td>
                <td>
                  <MeasurementValue m={rear?.electrical_power_w} unit="W" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        {out && out.limited_by.length > 0 && (
          <p className="mt-3 text-xs text-ink-3">Aktive Begrenzungen: {out.limited_by.join(', ')}</p>
        )}
        <div className="mt-4">
          <Button tone="ghost" onClick={() => navigate('fahrmodi')}>
            Achs- und Seitenbegrenzung im Profil „Custom“ einstellen →
          </Button>
        </div>
      </Card>
    </div>
  );
}
