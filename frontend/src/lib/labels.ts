// Deutsche Bezeichnungen für Protokollwerte.

import type { BrakeStateName, DriveModeName, ProfileName, VehicleStateName } from '../types/protocol';

export const PROFILE_LABEL: Record<ProfileName, string> = {
  eco: 'Eco',
  normal: 'Normal',
  sport: 'Sport',
  custom: 'Custom',
};

export const PROFILE_DESCRIPTION: Record<ProfileName, string> = {
  eco: 'Effizient & ausgewogen',
  normal: 'Alltagstauglich',
  sport: 'Direktes Ansprechen',
  custom: 'Individuell eingestellt',
};

export const DRIVE_MODE_LABEL: Record<DriveModeName, string> = {
  awd: 'Allrad',
  fwd: 'FWD',
  rwd: 'RWD',
  custom: 'Custom',
};

export const DRIVE_MODE_DESCRIPTION: Record<DriveModeName, string> = {
  awd: 'Beide Achsen nach Gewichtung',
  fwd: 'Nur Vorderachse treibt an',
  rwd: 'Nur Hinterachse treibt an',
  custom: 'Freie Verteilung vorne/hinten',
};

export const DRIVE_MODE_BADGE: Record<DriveModeName, string> = {
  awd: '4WD',
  fwd: 'FWD',
  rwd: 'RWD',
  custom: 'CUSTOM',
};

export const STATE_LABEL: Record<VehicleStateName, string> = {
  initializing: 'Initialisierung',
  locked: 'Motoren gesperrt',
  armed: 'Motoren freigegeben',
  fault: 'Fehler – gesperrt',
  emergency_stop: 'Not-Aus aktiv',
};

export const BRAKE_LABEL: Record<BrakeStateName, string> = {
  inactive: 'Bereit',
  coasting: 'Rollen – Antrieb aus',
  requested: 'Verzögerung angefordert',
  confirmed: 'Bremswirkung gemessen',
  unsupported: 'Nur Antrieb aus – keine verifizierte Bremse',
};

export const LIMIT_LABEL: Record<string, string> = {
  profil: 'Profilgrenze',
  rueckwaerts: 'Rückwärtsgrenze',
  akku: 'Akku-Schutz',
  temperatur: 'Temperatur',
  geschwindigkeit: 'Geschwindigkeitsgrenze',
  keine_geschwindigkeit: 'Keine Geschwindigkeitsmessung',
};
