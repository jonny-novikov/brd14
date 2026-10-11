// publish-manifest.ts — writes the manifest the published package ships with.
//
//   node ts/scripts/publish-manifest.ts ts/packages/brd14
//
// In the repository, packages/brd14/package.json points its exports at
// src/*.ts so Node (type stripping), Bun, vitest and tsc all run the sources
// unbuilt. npm does not apply `publishConfig.exports` when packing (verified
// with npm 11), so the publishable manifest is generated instead: after
// `tsc -p packages/brd14` has emitted dist/, this writes dist/package.json
// with the same exports rewritten to ./*.js + ./*.d.ts, copies the README and
// LICENSE, and the package is published from dist/:
//
//   npm publish ts/packages/brd14/dist
//
// Nothing in the tree is mutated, so a failed publish leaves nothing dirty.

import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";

interface Manifest {
  name: string;
  version: string;
  description?: string;
  keywords?: string[];
  license?: string;
  repository?: unknown;
  homepage?: string;
  bugs?: unknown;
  engines?: Record<string, string>;
  exports: Record<string, string>;
}

const pkgDir = resolve(process.argv[2] ?? ".");
const dist = resolve(pkgDir, "dist");
const src = JSON.parse(readFileSync(resolve(pkgDir, "package.json"), "utf8")) as Manifest;

const exports: Record<string, { types: string; default: string }> = {};
for (const [key, target] of Object.entries(src.exports)) {
  const m = /^\.\/src\/(.+)\.ts$/.exec(target);
  if (m === null) throw new Error(`publish-manifest: export ${key} → ${target} is not ./src/*.ts`);
  const stem = m[1]!;
  for (const f of [`${stem}.js`, `${stem}.d.ts`]) {
    if (!existsSync(resolve(dist, f))) throw new Error(`publish-manifest: dist/${f} missing — run tsc first`);
  }
  exports[key] = { types: `./${stem}.d.ts`, default: `./${stem}.js` };
}

const out = {
  name: src.name,
  version: src.version,
  description: src.description,
  keywords: src.keywords,
  license: src.license,
  repository: src.repository,
  homepage: src.homepage,
  bugs: src.bugs,
  type: "module",
  sideEffects: false,
  engines: src.engines,
  exports: { ...exports, "./package.json": "./package.json" },
};
writeFileSync(resolve(dist, "package.json"), JSON.stringify(out, null, 2) + "\n");

for (const [from, to] of [
  [resolve(pkgDir, "README.md"), "README.md"],
  [resolve(pkgDir, "../../../LICENSE"), "LICENSE"],
] as const) {
  if (existsSync(from)) copyFileSync(from, resolve(dist, to));
}

console.log(`publish-manifest: ${basename(pkgDir)} → ${dist}/package.json (npm publish ${dist})`);
