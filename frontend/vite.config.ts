/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The API runs on $CONDUCTOR_PORT (or 4000). The web dev server runs on the
// next port and proxies /api to the API, so the browser sees one origin.
const apiPort = Number(process.env.API_PORT ?? process.env.CONDUCTOR_PORT ?? 4000);
const webPort = Number(process.env.WEB_PORT ?? apiPort + 1);

export default defineConfig({
  plugins: [react()],
  server: {
    port: webPort,
    strictPort: true,
    proxy: {
      "/api": `http://127.0.0.1:${apiPort}`,
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./test/setup.ts"],
    globalSetup: ["./test/global-setup.ts"],
  },
});
