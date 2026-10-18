import { readFileSync, writeFileSync } from "node:fs";

const packagePath = new URL("../package.json", import.meta.url);
const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
const parts = String(packageJson.version || "0.0.0").split(".");
while (parts.length < 3) parts.push("0");
const patch = Number.parseInt(parts[2], 10);
if (!Number.isInteger(patch) || patch < 0) {
  throw new Error(`Cannot automatically increment invalid app version: ${packageJson.version}`);
}
parts[2] = String(patch + 1);
packageJson.version = parts.join(".");
writeFileSync(packagePath, JSON.stringify(packageJson, null, 2) + "\n");
console.log(`App version for this build: ${packageJson.version}`);
