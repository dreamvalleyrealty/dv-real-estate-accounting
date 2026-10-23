import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";

const packageJson = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
// Generate a readable build label on every build/deployment instead of appending
// a long, compact timestamp to the semantic version.
const buildStamp = new Date().toISOString().slice(0, 16).replace("T", " ");
const buildVersion = `${packageJson.version} (Build ${buildStamp} UTC)`;

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
