import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync, copyFileSync } from "node:fs";
import { resolve } from "node:path";

const packageJson = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));

export default defineConfig({
  plugins: [
    react(),
    {
      name: "dv-field-index",
      closeBundle() {
        copyFileSync(resolve(process.cwd(), "dist-field/field.html"), resolve(process.cwd(), "dist-field/index.html"));
      }
    }
  ],
  define: {
    __BUILD_VERSION__: JSON.stringify(packageJson.version)
  },
  build: {
    outDir: "dist-field",
    emptyOutDir: true,
    rollupOptions: {
      input: resolve(process.cwd(), "field.html")
    }
  }
});
