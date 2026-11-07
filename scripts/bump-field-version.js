import { readFileSync, writeFileSync } from "node:fs";

const versionPath = new URL("../field-version.json", import.meta.url);
const versionData = JSON.parse(readFileSync(versionPath, "utf8"));
const match = String(versionData.version || "1.00").match(/^(\d+)\.(\d{2})$/);
if (!match) throw new Error(`Expected field app version in major.minor format (for example 1.01): ${versionData.version}`);
let major = Number(match[1]);
let minor = Number(match[2]) + 1;
if (minor > 99) { major += 1; minor = 0; }
versionData.version = `${major}.${String(minor).padStart(2, "0")}`;
writeFileSync(versionPath, JSON.stringify(versionData, null, 2) + "\n");
console.log(`Field App version for this build: v${versionData.version}`);
