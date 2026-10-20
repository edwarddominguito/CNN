import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const apiProxy = Object.fromEntries(
  ['/predict', '/history', '/metrics', '/health', '/ready'].map((path) => [
    path,
    { target: 'http://127.0.0.1:8000', changeOrigin: true },
  ]),
)

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: { proxy: apiProxy },
  preview: { proxy: apiProxy },
})
