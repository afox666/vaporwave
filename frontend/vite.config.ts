import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

function normalizeBasePath(basePath: string | undefined): string {
  if (!basePath) return '/'
  if (basePath === '.' || basePath === './') return './'

  const withLeadingSlash = basePath.startsWith('/') ? basePath : `/${basePath}`
  return withLeadingSlash.endsWith('/') ? withLeadingSlash : `${withLeadingSlash}/`
}

export default defineConfig({
  base: normalizeBasePath(process.env.VITE_BASE_PATH),
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8000',
        changeOrigin: true,
      },
    },
  },
})
