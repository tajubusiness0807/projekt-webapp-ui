// Fahrereingaben (Totmann-Kanäle) mit reaktiver Anzeige.
//
// Die Kanäle selbst (Werte + Lease-Zeitstempel) liegen außerhalb von React, damit der 20-Hz-Sender
// und 60-Hz-Erneuerungen keine Renderzyklen auslösen. Für die Anzeige (Pedal-Füllstand,
// Lenkanzeige) gibt es zusätzlich einen kleinen reaktiven Store.

import { create } from 'zustand';
import { InputChannels, type ChannelName } from '../lib/deadman';
import type { InputSource } from '../types/protocol';

export const channels = new InputChannels();

interface InputView {
  throttle: number;
  brake: number;
  steer: number;
  tiltActive: boolean;
  /** Wird bei jedem globalen Zurücksetzen erhöht – gedrückte Bedienelemente müssen neu betätigt werden. */
  epoch: number;
}

export const useInputView = create<InputView>(() => ({ throttle: 0, brake: 0, steer: 0, tiltActive: false, epoch: 0 }));

export function setInput(name: ChannelName, value: number, source: InputSource): void {
  channels.set(name, value, source, performance.now());
  if (useInputView.getState()[name] !== value) useInputView.setState({ [name]: value } as Partial<InputView>);
}

export function refreshInput(name: ChannelName): void {
  channels.refresh(name, performance.now());
}

export function releaseInput(name: ChannelName): void {
  channels.release(name);
  if (useInputView.getState()[name] !== 0) useInputView.setState({ [name]: 0 } as Partial<InputView>);
}

export function releaseAllInputs(): void {
  channels.releaseAll();
  held.gas = false;
  held.brake = false;
  useInputView.setState((s) => ({ throttle: 0, brake: 0, steer: 0, epoch: s.epoch + 1 }));
}

export function readInputs() {
  return channels.read(performance.now());
}

/** Ob ein Pedal gerade physisch gehalten wird (für Neigungs-Gas, das nur mit gehaltenem Gaspedal wirkt). */
export const held = { gas: false, brake: false };
