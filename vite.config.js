import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";

const packageJson = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
const buildStamp = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 12);
const deploymentId = process.env.GITHUB_RUN_NUMBER || process.env.CI_PIPELINE_ID || process.env.BUILD_NUMBER || buildStamp;
const buildVersion = `${packageJson.version}.${deploymentId}`;

export default defineConfig({
  plugins: [react()],
  define: {
    __BUILD_VERSION__: JSON.stringify(buildVersion)
  },
  server: {
    host: "0.0.0.0"
  },
  preview: {
    host: "0.0.0.0"
  }
});