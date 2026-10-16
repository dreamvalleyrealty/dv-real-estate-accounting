import { readFileSync, writeFileSync } from "node:fs";

const packagePath = new URL("../package.json", import.meta.url);
const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
const parts = String(packageJson.version || "0.0.0").split(".").map(Number);

while (parts.length < 3) parts.push(0);
parts[2] += 1;
packageJson.version = parts.join(".");

writeFileSync(packagePath, JSON.stringify(packageJson, null, 2) + "\n");
console.log(`Build version bumped to ${packageJson.version}`);
