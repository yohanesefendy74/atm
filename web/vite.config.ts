import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Hasil build langsung ke wwwroot API -> web & API satu origin (tanpa CORS, cookie SameSite=Strict).
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../api/GudangAtm.Api/wwwroot',
    emptyOutDir: true,
    sourcemap: false,
  },
  server: {
    // npm run dev: teruskan /api ke API lokal (appsettings.Development.json, http://localhost:5080)
    proxy: { '/api': 'http://localhost:5080' },
  },
});
