import { KeyRound, LogIn } from 'lucide-react';
import { useState } from 'react';
import { Logo } from '../components/common/Icons';
import { api, ApiError } from '../services/api';
import { useAuth } from '../stores/authStore';

export function LoginPage({ message }: { message?: string | null }) {
  const [secret, setSecret] = useState('');
  const [admin, setAdmin] = useState(false);
  const [error, setError] = useState<string | null>(message ?? null);
  const [busy, setBusy] = useState(false);
  const setDriver = useAuth((s) => s.setDriver);
  const setAdminToken = useAuth((s) => s.setAdmin);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const result = await api.login(secret, admin ? 'admin' : 'driver');
      if (admin) setAdminToken(result.token);
      setDriver(result.token, result.role);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Anmeldung fehlgeschlagen');
    } finally {
      setBusy(false);
      setSecret('');
    }
  };

  return (
    <div className="flex min-h-full items-center justify-center p-4">
      <form onSubmit={submit} className="card w-full max-w-sm p-6 sm:p-8">
        <div className="mb-6 flex flex-col items-center gap-3 text-center">
          <Logo size={44} />
          <h1 className="text-2xl font-semibold tracking-tight text-ink">AllWheel Control</h1>
          <p className="text-sm text-ink-2">Anmeldung am Fahrzeug</p>
        </div>
        <label className="block text-sm text-ink-2">
          {admin ? 'Administrator-Passwort' : 'Fahrer-PIN'}
          <input
            className="input mt-1.5 w-full text-center text-2xl tracking-[0.4em]"
            type="password"
            inputMode={admin ? 'text' : 'numeric'}
            autoComplete={admin ? 'current-password' : 'one-time-code'}
            autoFocus
            value={secret}
            onChange={(e) => setSecret(e.target.value)}
            aria-label={admin ? 'Administrator-Passwort' : 'Fahrer-PIN'}
          />
        </label>
        {error && (
          <p className="mt-3 text-sm text-danger" role="alert">
            {error}
          </p>
        )}
        <button
          type="submit"
          disabled={!secret || busy}
          className="mt-5 flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-accent font-semibold text-white shadow-glow-accent disabled:opacity-40"
        >
          <LogIn className="h-5 w-5" /> Anmelden
        </button>
        <button type="button" onClick={() => setAdmin(!admin)} className="mt-4 flex w-full items-center justify-center gap-1.5 text-sm text-ink-3 hover:text-ink-2">
          <KeyRound className="h-4 w-4" />
          {admin ? 'Als Fahrer anmelden' : 'Als Administrator anmelden'}
        </button>
        {import.meta.env.MODE === 'demo' && (
          <p className="mt-5 rounded-xl border border-warn/40 bg-warn-soft/60 px-3 py-2 text-center text-sm text-warn">
            Browser-Demo ohne Fahrzeug · PIN <strong>1234</strong> · Admin-Passwort <strong>admin1234</strong>
          </p>
        )}
        <p className="mt-6 text-center text-xs leading-relaxed text-ink-4">
          PIN und Passwort werden in der Dienstkonfiguration festgelegt. Wurden keine gesetzt, stehen die erzeugten Zugangsdaten in
          <code className="mx-1">credentials.json</code>im Datenverzeichnis des Raspberry Pi.
        </p>
      </form>
    </div>
  );
}
