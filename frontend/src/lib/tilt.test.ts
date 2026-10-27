import { describe, expect, it } from 'vitest';
import { LowPass, anglesFromGravity, angleDelta, steerFromRoll, throttleFromPitch, type TiltSettings } from './tilt';

const settings: TiltSettings = {
  full_lock_angle_deg: 25,
  max_steer_percent: 80,
  deadzone_deg: 3,
  smoothing: 0.6,
  invert: false,
  pitch_function: 'off',
  pitch_full_angle_deg: 20,
  pitch_deadzone_deg: 5,
};

const g = 9.81;
const rad = (d: number) => (d * Math.PI) / 180;

describe('anglesFromGravity', () => {
  it('Hochformat aufrecht = 0°', () => {
    const a = anglesFromGravity(0, g, 0, 0);
    expect(a.valid).toBe(true);
    expect(a.roll).toBeCloseTo(0, 5);
  });

  it('Hochformat 20° im Uhrzeigersinn gedreht = +20°', () => {
    // Gerät im Uhrzeigersinn gedreht: „oben“ erscheint links → gx negativ
    const a = anglesFromGravity(-g * Math.sin(rad(20)), g * Math.cos(rad(20)), 0, 0);
    expect(a.roll).toBeCloseTo(20, 3);
  });

  it('Querformat (Bildschirmwinkel 90°): Lenkbewegung wird korrekt erkannt', () => {
    // Querformat, aufrecht: Bildschirm-oben entspricht Geräte-x
    const upright = anglesFromGravity(g, 0, 0, 90);
    expect(upright.valid).toBe(true);
    expect(upright.roll).toBeCloseTo(0, 5);
    // 15° im Uhrzeigersinn: Bildschirmvektor (−sin, cos) → Gerätekoordinaten zurückrechnen
    const t = rad(15);
    const sx = -g * Math.sin(t);
    const sy = g * Math.cos(t);
    // Umkehrung der Drehung um 90°: gx = sx·cos + sy·sin, gy = −sx·sin + sy·cos
    const a = anglesFromGravity(sx * Math.cos(rad(90)) + sy * Math.sin(rad(90)), -sx * Math.sin(rad(90)) + sy * Math.cos(rad(90)), 0, 90);
    expect(a.roll).toBeCloseTo(15, 3);
  });

  it('flach liegend ist ungültig', () => {
    expect(anglesFromGravity(0.2, 0.3, g, 0).valid).toBe(false);
  });

  it('fehlende Werte sind ungültig', () => {
    expect(anglesFromGravity(null, 1, 1, 0).valid).toBe(false);
    expect(anglesFromGravity(Number.NaN, 1, 1, 0).valid).toBe(false);
  });
});

describe('steerFromRoll', () => {
  it('Totzone, Skalierung und Begrenzung', () => {
    expect(steerFromRoll(2, 0, settings)).toBe(0);
    expect(steerFromRoll(25, 0, settings)).toBeCloseTo(0.8, 5);
    expect(steerFromRoll(60, 0, settings)).toBeCloseTo(0.8, 5);
    expect(steerFromRoll(-14, 0, settings)).toBeCloseTo(-0.8 * (11 / 22), 5);
  });
  it('relativ zur kalibrierten Neutrallage und invertierbar', () => {
    expect(steerFromRoll(10, 10, settings)).toBe(0);
    expect(steerFromRoll(35, 10, { ...settings, invert: true })).toBeCloseTo(-0.8, 5);
  });
  it('Winkeldifferenz über ±180°', () => {
    expect(angleDelta(179, -179)).toBeCloseTo(-2);
  });
});

describe('throttleFromPitch', () => {
  it('standardmäßig deaktiviert', () => {
    expect(throttleFromPitch(-30, 0, settings)).toBe(0);
  });
  it('aktiviert mit Totzone', () => {
    const s = { ...settings, pitch_function: 'throttle' as const };
    expect(throttleFromPitch(-4, 0, s)).toBe(0);
    expect(throttleFromPitch(-20, 0, s)).toBe(1);
    expect(throttleFromPitch(-12.5, 0, s)).toBeCloseTo(0.5, 5);
  });
});

describe('LowPass', () => {
  it('glättet', () => {
    const lp = new LowPass(0.5);
    expect(lp.update(10)).toBe(10);
    expect(lp.update(0)).toBe(5);
  });
});
