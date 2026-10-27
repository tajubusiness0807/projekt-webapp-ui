/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Backend-Adresse für die Entwicklung (python -m app, Standardport 8080)
const backend = process.env.AWC_BACKEND ?? 'http://127.0.0.1:8080';

export default defineConfig({
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
    sourcemap: false,
    chunkSizeWarningLimit: 600,
    // Alle Ressourcen lokal bündeln – keine externen CDNs (Offline-Betrieb im Fahrzeug-WLAN)
    assetsInlineLimit: 4096,
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
});
