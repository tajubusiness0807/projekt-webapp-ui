// Tastatursteuerung für Desktop/Tablet mit Tastatur: W/↑ Gas, S/↓/Leertaste Bremse, A/← und D/→ Lenkung.
// Totmann: Werte gelten nur, solange die Taste gehalten wird; Fokusverlust setzt alles auf 0.

import { useEffect } from 'react';
import { refreshInput, releaseInput, setInput } from '../stores/inputStore';
import { useVehicle } from '../stores/vehicleStore';

const GAS = new Set(['KeyW', 'ArrowUp']);
const BRAKE = new Set(['KeyS', 'ArrowDown', 'Space']);
const LEFT = new Set(['KeyA', 'ArrowLeft']);
const RIGHT = new Set(['KeyD', 'ArrowRight']);

export function useKeyboardControl(enabled: boolean): void {
  useEffect(() => {
    if (!enabled) return;
    const held = new Set<string>();

    const apply = () => {
      const gasLevel = (useVehicle.getState().settings?.ui.keyboard_throttle_percent ?? 50) / 100;
      const gas = [...held].some((k) => GAS.has(k));
      const brake = [...held].some((k) => BRAKE.has(k));
      const left = [...held].some((k) => LEFT.has(k));
      const right = [...held].some((k) => RIGHT.has(k));
      if (brake) setInput('brake', 1, 'keyboard');
      else releaseInput('brake');
      if (gas && !brake) setInput('throttle', gasLevel, 'keyboard');
      else releaseInput('throttle');
      const steer = (right ? 1 : 0) - (left ? 1 : 0);
      if (steer !== 0) setInput('steer', steer, 'keyboard');
      else releaseInput('steer');
    };

    const isTyping = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable);
    };
    const onDown = (e: KeyboardEvent) => {
      if (isTyping(e)) return;
      if (GAS.has(e.code) || BRAKE.has(e.code) || LEFT.has(e.code) || RIGHT.has(e.code)) {
        e.preventDefault();
        held.add(e.code);
        apply();
      }
    };
    const onUp = (e: KeyboardEvent) => {
      if (held.delete(e.code)) apply();
    };
    const clear = () => {
      held.clear();
      apply();
    };
    // Gehaltene Tasten erneuern die Lease (keydown-Wiederholung ist nicht zuverlässig).
    const refresher = window.setInterval(() => {
      if (held.size === 0) return;
      refreshInput('throttle');
      refreshInput('brake');
      refreshInput('steer');
    }, 80);

    window.addEventListener('keydown', onDown);
    window.addEventListener('keyup', onUp);
    window.addEventListener('blur', clear);
    return () => {
      window.clearInterval(refresher);
      window.removeEventListener('keydown', onDown);
      window.removeEventListener('keyup', onUp);
      window.removeEventListener('blur', clear);
      held.clear();
      releaseInput('throttle');
      releaseInput('brake');
      releaseInput('steer');
    };
  }, [enabled]);
}
