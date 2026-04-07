import { rmSync } from 'node:fs'
import react from '@vitejs/plugin-react'
import tsconfigPaths from 'vite-tsconfig-paths'
import { defineConfig } from 'vite'

const outDir = 'dist-cli/html'

// Woods fork: simplified config — no CLI binary plugins, no git tag fetching
export default defineConfig({
  base: './',
  build: {
    chunkSizeWarningLimit: 5000,
    emptyOutDir: true,
    outDir,
    rollupOptions: {
      plugins: [
        {
          name: 'exclude-schema-json',
          closeBundle() {
            rmSync(`${outDir}/schema.json`, { force: true })
          },
        },
      ],
    },
  },
  plugins: [react(), tsconfigPaths()],
})
