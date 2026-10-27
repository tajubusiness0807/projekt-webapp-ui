import '@fontsource/inter/latin-400.css';
import '@fontsource/inter/latin-500.css';
import '@fontsource/inter/latin-600.css';
import '@fontsource/inter/latin-700.css';
import './styles/index.css';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { ErrorBoundary } from './components/common/ErrorBoundary';

async function boot(): Promise<void> {
  // Browser-Demo (npm run build:demo): Backend wird im Browser simuliert. Im normalen Build entfällt dieser Zweig.
  if (import.meta.env.MODE === 'demo') {
    const { installMockBackend } = await import('./demo/mockBackend');
    installMockBackend();
  }
  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </StrictMode>,
  );
}

void boot();
