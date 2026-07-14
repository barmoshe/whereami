import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Served from https://barmoshe.github.io/whereami/
export default defineConfig({
  base: '/whereami/',
  plugins: [react()],
})
