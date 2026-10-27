import { describe, expect, it } from 'vitest';
import { InputChannels, LEASE_MS, pedalValue } from './deadman';

describe('InputChannels (Totmann)', () => {
  it('verfällt ohne Erneuerung nach der Lease-Zeit auf 0', () => {
    const ch = new InputChannels();
    ch.set('throttle', 0.8, 'pedals', 1000);
    expect(ch.read(1000 + LEASE_MS - 1).throttle).toBe(0.8);
    expect(ch.read(1000 + LEASE_MS + 1).throttle).toBe(0);
  });

  it('bleibt aktiv, solange die Quelle erneuert', () => {
    const ch = new InputChannels();
    ch.set('throttle', 0.5, 'pedals', 0);
    for (let t = 100; t <= 2000; t += 100) ch.refresh('throttle', t);
    expect(ch.read(2100).throttle).toBe(0.5);
  });

  it('Loslassen setzt sofort auf 0', () => {
    const ch = new InputChannels();
    ch.set('throttle', 1, 'pedals', 0);
    ch.release('throttle');
    expect(ch.read(1).throttle).toBe(0);
  });

  it('Bremse hat Vorrang vor Gas', () => {
    const ch = new InputChannels();
    ch.set('throttle', 1, 'pedals', 0);
    ch.set('brake', 1, 'pedals', 0);
    const inputs = ch.read(10);
    expect(inputs.throttle).toBe(0);
    expect(inputs.brake).toBe(1);
  });

  it('begrenzt Werte und verwirft NaN', () => {
    const ch = new InputChannels();
    ch.set('throttle', 5, 'pedals', 0);
    ch.set('steer', -3, 'tilt', 0);
    expect(ch.read(1)).toMatchObject({ throttle: 1, steer: -1 });
    ch.set('throttle', Number.NaN, 'pedals', 0);
    expect(ch.read(1).throttle).toBe(0);
  });

  it('releaseAll setzt alle Kanäle zurück', () => {
    const ch = new InputChannels();
    ch.set('throttle', 1, 'joystick', 0);
    ch.set('steer', 0.5, 'joystick', 0);
    ch.releaseAll();
    expect(ch.read(1)).toEqual({ throttle: 0, brake: 0, steer: 0, source: 'none' });
  });
});

describe('pedalValue', () => {
  it('proportional mit Mindestwert', () => {
    expect(pedalValue(0, 'proportional')).toBe(0.1);
    expect(pedalValue(1, 'proportional')).toBe(1);
    expect(pedalValue(0.5, 'proportional')).toBeCloseTo(0.5, 2);
  });
  it('voll-Modus', () => {
    expect(pedalValue(0.2, 'full')).toBe(1);
  });
});
