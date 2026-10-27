/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Backend-Adresse für die Entwicklung (python -m app, Standardport 8080)
const backend = process.env.AWC_BACKEND ?? 'http://127.0.0.1:8080';

export default defineConfig(({ mode }) => ({
  // Modus „demo“: Browser-Demo mit simuliertem Backend, relative Pfade, Schriften eingebettet, eine JS-Datei.
  base: mode === 'demo' ? './' : '/',
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
    proxy: {
      '/api': { target: backend, changeOrigin: false },
      '/ws': { target: backend.replace(/^http/, 'ws'), ws: true, changeOrigin: false },
    },
  },
  build: {
    target: ['es2020', 'safari14'],
    outDir: mode === 'demo' ? 'dist-demo' : 'dist',
    sourcemap: false,
    chunkSizeWarningLimit: 700,
    // Alle Ressourcen lokal bündeln – keine externen CDNs (Offline-Betrieb im Fahrzeug-WLAN)
    assetsInlineLimit: mode === 'demo' ? 200_000 : 4096,
    rollupOptions: mode === 'demo' ? { output: { inlineDynamicImports: true } } : undefined,
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
}));
