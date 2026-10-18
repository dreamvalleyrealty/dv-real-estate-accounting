import { readFileSync, writeFileSync } from "node:fs";

const packagePath = new URL("../package.json", import.meta.url);
const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
const match = String(packageJson.version || "1.00").match(/^(\d+)\.(\d{1,2})$/);
if (!match) {
  throw new Error(`Expected app version in major.minor format (for example 1.01): ${packageJson.version}`);
}
let major = Number(match[1]);
let minor = Number(match[2]) + 1;
if (minor > 10) {
  major += 1;
  minor = 1;
}
packageJson.version = `${major}.${String(minor).padStart(2, "0")}`;
writeFileSync(packagePath, JSON.stringify(packageJson, null, 2) + "\n");
console.log(`App version for this build: v${packageJson.version}`);
