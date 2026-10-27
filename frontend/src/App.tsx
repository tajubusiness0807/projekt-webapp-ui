import { useEffect, type ReactElement } from 'react';
import { ErrorBoundary } from './components/common/ErrorBoundary';
import { Toaster } from './components/common/Toaster';
import { FaultBanner } from './components/layout/FaultBanner';
import { Header } from './components/layout/Header';
import { BottomNav, Sidebar } from './components/layout/Navigation';
import { useIsOwner } from './hooks/common';
import { useDriveSender } from './hooks/useDriveSender';
import { useKeyboardControl } from './hooks/useKeyboardControl';
import { useRoute, type RouteName } from './hooks/useRoute';
import { ConnectionPage } from './pages/ConnectionPage';
import { DashboardPage } from './pages/DashboardPage';
import { DiagnosticsPage } from './pages/DiagnosticsPage';
import { DrivePage } from './pages/DrivePage';
import { LoginPage } from './pages/LoginPage';
import { ModesPage } from './pages/ModesPage';
import { PowerPage } from './pages/PowerPage';
import { SettingsPage } from './pages/SettingsPage';
import { SystemPage } from './pages/SystemPage';
import { socket } from './services/wsClient';
import { stopTilt } from './services/tiltController';
import { useAuth } from './stores/authStore';
import { useVehicle } from './stores/vehicleStore';

const PAGES: Record<Exclude<RouteName, 'fahren'>, () => ReactElement | null> = {
  dashboard: DashboardPage,
  fahrmodi: ModesPage,
  leistung: PowerPage,
  einstellungen: SettingsPage,
  verbindung: ConnectionPage,
  diagnose: DiagnosticsPage,
  system: SystemPage,
};

function Shell() {
  const route = useRoute();
  const owner = useIsOwner();
  const settings = useVehicle((s) => s.settings);
  useDriveSender();
  useKeyboardControl(owner && (route === 'fahren' || route === 'dashboard'));

  // Neigungssteuerung beim Verlassen der Fahransicht ausschalten (keine verwaisten Lenkanforderungen).
  useEffect(() => {
    if (route !== 'fahren') stopTilt();
  }, [route]);

  if (!settings) {
    return (
      <div className="flex h-full flex-col">
        <Header />
        <FaultBanner />
        <div className="flex flex-1 items-center justify-center text-ink-2">Verbinde mit dem Fahrzeug …</div>
      </div>
    );
  }

  if (route === 'fahren') {
    return (
      <div className="flex h-full flex-col">
        <Header showDashboardLink />
        <FaultBanner />
        <ErrorBoundary>
          <DrivePage />
        </ErrorBoundary>
      </div>
    );
  }

  const Page = PAGES[route];
  return (
    <div className="flex h-full flex-col">
      <Header />
      <FaultBanner />
      <div className="flex min-h-0 flex-1">
        <Sidebar />
        <main className="min-w-0 flex-1 overflow-y-auto">
          <ErrorBoundary>
            <Page />
          </ErrorBoundary>
        </main>
      </div>
      <BottomNav />
    </div>
  );
}

export function App() {
  const token = useAuth((s) => s.token);
  const logout = useAuth((s) => s.logout);
  const connMessage = useVehicle((s) => s.connMessage);
  const conn = useVehicle((s) => s.conn);

  useEffect(() => {
    if (!token) return;
    socket.onAuthFailed = () => logout();
    socket.start(token);
    return () => socket.stop();
  }, [token, logout]);

  return (
    <>
      {token ? <Shell /> : <LoginPage message={conn === 'auth_failed' ? connMessage : null} />}
      <Toaster />
    </>
  );
}
