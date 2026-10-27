// Fahrmodi: Profilwahl, Profilparameter (validiert und vom Backend begrenzt), Antriebsmodi.

import { RotateCcw } from 'lucide-react';
import { useState } from 'react';
import { DriveModeList, PROFILE_ICON, ProfileTiles } from '../components/controls/ModeSelectors';
import { SettingSlider } from '../components/controls/SettingSlider';
import { Badge, Button, Card, Notice, Segmented } from '../components/common/ui';
import { useIsOwner } from '../hooks/common';
import { formatNumber } from '../lib/format';
import { PROFILE_DESCRIPTION, PROFILE_LABEL } from '../lib/labels';
import { command } from '../services/wsClient';
import { updateDriverSettings } from '../services/settings';
import { useVehicle } from '../stores/vehicleStore';
import type { DriveProfileSettings, ProfileName } from '../types/protocol';

const PROFILE_GOALS: Record<ProfileName, string> = {
  eco: 'Sanfte Beschleunigung, reduzierte Leistung, konservative Geschwindigkeitsgrenze.',
  normal: 'Ausgewogene Beschleunigung und mittlere Leistungsgrenze für den Alltag.',
  sport: 'Direktes Ansprechen und höhere Beschleunigung – Sicherheitsgrenzen gelten trotzdem.',
  custom: 'Alle Parameter einschließlich Achs- und Seitenbegrenzung frei einstellbar.',
};

export function ModesPage() {
  const settings = useVehicle((s) => s.settings);
  const caps = useVehicle((s) => s.capabilities);
  const active = useVehicle((s) => s.telemetry?.vehicle.profile ?? 'eco');
  const owner = useIsOwner();
  const [edit, setEdit] = useState<ProfileName>(active);
  if (!settings || !caps) return null;

  const profile = settings.profiles[edit];
  const effective = caps.effective_profiles[edit];
  const safety = settings.safety;
  const patch = (field: keyof DriveProfileSettings, value: number) => updateDriverSettings({ profiles: { [edit]: { [field]: value } } });
  const limitHint = (field: string) =>
    effective?.limited[field] ? (
      <span className="text-warn">
        Wirksam begrenzt ({effective.limited[field]}): {formatNumber(Number((effective as unknown as Record<string, number>)[field]), 0)}
      </span>
    ) : undefined;

  return (
    <div className="page-grid">
      <Card title="Fahrprofil">
        <ProfileTiles />
        <p className="mt-3 text-sm text-ink-2">{PROFILE_GOALS[active]}</p>
        {!owner && <Notice kind="info">Nur das steuernde Gerät kann Profile wählen und ändern.</Notice>}
      </Card>

      <Card title="Antriebsmodus">
        <DriveModeList />
        <p className="mt-3 text-xs leading-relaxed text-ink-3">
          Die Zuordnung der Controller zu Vorder- und Hinterachse wird in den Einstellungen (Administration → Controller) festgelegt.
          {caps.mode === 'hardware' && !caps.axle_distribution.available && ` ${caps.axle_distribution.reason}`}
        </p>
      </Card>

      <Card
        title="Profilparameter"
        className="lg:col-span-2"
        action={
          <Button tone="ghost" disabled={!owner} onClick={() => command('reset_profiles', {}, 'Profile auf Standardwerte zurückgesetzt')}>
            <RotateCcw className="h-4 w-4" /> Standardwerte
          </Button>
        }
      >
        <div className="mb-4 flex flex-wrap items-center gap-3">
          <Segmented<ProfileName>
            value={edit}
            onChange={setEdit}
            options={(['eco', 'normal', 'sport', 'custom'] as ProfileName[]).map((p) => {
              const Icon = PROFILE_ICON[p];
              return {
                value: p,
                label: (
                  <span className="flex items-center gap-1.5">
                    <Icon className="h-4 w-4" />
                    {PROFILE_LABEL[p]}
                  </span>
                ),
              };
            })}
          />
          {edit === active && <Badge tone="ok">aktiv</Badge>}
          <span className="text-sm text-ink-3">{PROFILE_DESCRIPTION[edit]}</span>
        </div>
        <div className="grid gap-x-10 md:grid-cols-2">
          <SettingSlider label="Maximale Gasstellung" value={profile.max_throttle_percent} min={5} max={100} unit="%" disabled={!owner} hint={limitHint('max_throttle_percent')} onCommit={(v) => patch('max_throttle_percent', v)} />
          <SettingSlider label="Beschleunigungsrampe" value={profile.accel_ramp_percent_per_s} min={5} max={400} unit="%/s" disabled={!owner} hint={limitHint('accel_ramp_percent_per_s') ?? 'Wie schnell die Motoranforderung steigen darf. Loslassen wirkt sofort.'} onCommit={(v) => patch('accel_ramp_percent_per_s', v)} />
          <SettingSlider label="Verzögerungsanforderung" value={profile.brake_strength_percent} min={10} max={100} unit="%" disabled={!owner} hint="Stärke der Bremsanforderung bei voller Bremse – nur mit verifizierter Bremsfunktion wirksam." onCommit={(v) => patch('brake_strength_percent', v)} />
          <SettingSlider label="Maximale Geschwindigkeit" value={profile.max_speed_kmh} min={1} max={60} unit="km/h" disabled={!owner} hint={limitHint('max_speed_kmh') ?? `Absolute Grenze: ${safety.absolute_max_speed_kmh} km/h`} onCommit={(v) => patch('max_speed_kmh', v)} />
          <SettingSlider label="Lenkempfindlichkeit" value={profile.steering_sensitivity_percent} min={10} max={100} unit="%" disabled={!owner} onCommit={(v) => patch('steering_sensitivity_percent', v)} />
          <SettingSlider label="Totzone" value={profile.deadzone_percent} min={0} max={25} unit="%" disabled={!owner} hint="Kleine Eingaben unterhalb der Totzone werden ignoriert." onCommit={(v) => patch('deadzone_percent', v)} />
        </div>
        {edit === 'custom' && (
          <>
            <h3 className="mb-1 mt-5 text-sm font-semibold text-ink">Achs- und Seitenbegrenzung (Custom)</h3>
            <div className="grid gap-x-10 md:grid-cols-2">
              <SettingSlider label="Vorderachsleistung" value={profile.front_power_limit_percent} min={0} max={100} unit="%" disabled={!owner} onCommit={(v) => patch('front_power_limit_percent', v)} />
              <SettingSlider label="Hinterachsleistung" value={profile.rear_power_limit_percent} min={0} max={100} unit="%" accent="ok" disabled={!owner} onCommit={(v) => patch('rear_power_limit_percent', v)} />
              <SettingSlider label="Begrenzung links" value={profile.left_limit_percent} min={50} max={100} unit="%" disabled={!owner} hint="Gleicht z. B. ungleiche Räder aus." onCommit={(v) => patch('left_limit_percent', v)} />
              <SettingSlider label="Begrenzung rechts" value={profile.right_limit_percent} min={50} max={100} unit="%" disabled={!owner} onCommit={(v) => patch('right_limit_percent', v)} />
            </div>
          </>
        )}
        <p className="mt-4 text-xs text-ink-3">
          Alle Werte werden vom Fahrzeug geprüft und zur Laufzeit zusätzlich auf die Sicherheitsgrenzen begrenzt
          (max. {safety.absolute_max_speed_kmh} km/h, max. {safety.absolute_max_throttle_percent} % Gas, max. {safety.absolute_max_accel_ramp_percent_per_s} %/s Rampe).
        </p>
      </Card>
    </div>
  );
}
