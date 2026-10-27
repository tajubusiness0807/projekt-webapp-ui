import { Component, type ErrorInfo, type ReactNode } from 'react';
import { releaseAllInputs } from '../../stores/inputStore';

/** Fängt Darstellungsfehler ab. Alle Eingaben werden sofort auf 0 gesetzt. */
export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    releaseAllInputs();
    console.error('Darstellungsfehler', error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="flex min-h-full items-center justify-center p-6">
        <div className="card max-w-md p-6 text-center">
          <h1 className="text-lg font-semibold text-ink">Darstellungsfehler</h1>
          <p className="mt-2 text-sm text-ink-2">
            Die Oberfläche ist auf einen Fehler gestoßen. Alle Fahranforderungen wurden auf 0 gesetzt; das Fahrzeug stoppt über
            den Watchdog, falls die Verbindung bestehen bleibt.
          </p>
          <pre className="mt-3 overflow-x-auto rounded-lg bg-bg-1 p-2 text-left text-xs text-ink-3">{this.state.error.message}</pre>
          <button type="button" className="mt-4 rounded-xl bg-accent px-4 py-2 font-medium text-white" onClick={() => window.location.reload()}>
            Neu laden
          </button>
        </div>
      </div>
    );
  }
}
