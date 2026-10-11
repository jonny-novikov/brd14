// publish-deps.ts — adds `dependencies` to the dist/package.json that
// ../../scripts/publish-manifest.ts generated. That script writes the publishable
// manifest for a dependency-free package; this package depends on `brd14`, and the
// published manifest must say so.
//
//   node ts/packages/brd14-wasm/scripts/publish-deps.ts ts/packages/brd14-wasm

import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const pkgDir = resolve(process.argv[2] ?? ".");
const distManifest = resolve(pkgDir, "dist/package.json");
const src = JSON.parse(readFileSync(resolve(pkgDir, "package.json"), "utf8")) as { dependencies?: Record<string, string> };
const dist = JSON.parse(readFileSync(distManifest, "utf8")) as Record<string, unknown>;

dist["dependencies"] = src.dependencies ?? {};
writeFileSync(distManifest, JSON.stringify(dist, null, 2) + "\n");
console.log(`publish-deps: ${distManifest} dependencies ${JSON.stringify(dist["dependencies"])}`);
