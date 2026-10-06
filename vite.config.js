import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'node:path'

export default defineConfig({
  plugins: [react()],
  build: {
    rolldownOptions: {
      input: {
        main: resolve(process.cwd(), 'index.html'),
        services: resolve(process.cwd(), 'services/index.html'),
        shop: resolve(process.cwd(), 'shop/index.html'),
        contact: resolve(process.cwd(), 'contact/index.html'),
      },
    },
  },
})
