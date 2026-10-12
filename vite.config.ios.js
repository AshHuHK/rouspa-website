import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';

export default defineConfig({
  root: resolve(process.cwd(), 'mobile'),
  publicDir: resolve(process.cwd(), 'public'),
  base: './',
  plugins: [react()],
  resolve: {
    alias: {
      '/src': resolve(process.cwd(), 'src'),
    },
  },
  build: {
    outDir: resolve(process.cwd(), 'dist-ios'),
    emptyOutDir: true,
  },
});
