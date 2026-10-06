import { resolve } from 'node:path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The webview bundle. Tauri serves `dist/` in production and this dev server
// (port 5173, strict) in `tauri dev`; the Playwright layout harness drives the
// same server in Chromium with the browser shim standing in for the core.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  resolve: { alias: { '@shared': resolve(__dirname, 'src/shared') } },
  server: { port: 5173, strictPort: true, host: '127.0.0.1' },
  envPrefix: ['VITE_', 'TAURI_ENV_'],
  build: {
    target: 'es2022',
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: false,
    chunkSizeWarningLimit: 2000,
  },
  worker: { format: 'es' },
});
