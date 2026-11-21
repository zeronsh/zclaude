import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  build: { target: 'es2022', outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 2000 },
  // `bun run dev` serves the UI with hot reload; start `bun server.ts --port 7777`
  // too, and open http://localhost:5173/?t=TOKEN.
  server: { proxy: { '/ws': { target: 'ws://127.0.0.1:7777', ws: true } } },
});
