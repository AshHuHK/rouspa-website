import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'node:path'
import { createPublicRpcHandler } from './server/public-rpc.mjs'

// Vercel runs api/public-rpc.js in production. Use the same handler locally so
// dev and production previews exercise the same public transport and deadlines.
function publicRpcLocalServer() {
  const attach = server => { server.middlewares.use('/api/public-rpc', createPublicRpcHandler({ env: { NODE_ENV: 'development' } })) }
  return { name: 'public-rpc-local-server', configureServer: attach, configurePreviewServer: attach }
}

export default defineConfig({
  plugins: [react(), publicRpcLocalServer()],
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
