import { create } from 'zustand';

export type ToastKind = 'info' | 'success' | 'warning' | 'error';

export interface Toast {
  id: number;
  kind: ToastKind;
  message: string;
}

interface ToastState {
  toasts: Toast[];
  push(kind: ToastKind, message: string, durationMs?: number): void;
  dismiss(id: number): void;
}

let nextId = 1;

export const useToasts = create<ToastState>((set, get) => ({
  toasts: [],
  push(kind, message, durationMs = 4000) {
    const id = nextId++;
    // Gleiche Meldung nicht stapeln
    const existing = get().toasts.filter((t) => t.message !== message);
    set({ toasts: [...existing.slice(-3), { id, kind, message }] });
    window.setTimeout(() => get().dismiss(id), durationMs);
  },
  dismiss(id) {
    set({ toasts: get().toasts.filter((t) => t.id !== id) });
  },
}));

export const toast = {
  info: (m: string) => useToasts.getState().push('info', m),
  success: (m: string) => useToasts.getState().push('success', m, 2500),
  warning: (m: string) => useToasts.getState().push('warning', m, 5000),
  error: (m: string) => useToasts.getState().push('error', m, 6000),
};
