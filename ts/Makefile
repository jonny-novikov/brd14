# ts/ — the TypeScript workspace: packages/brd14 (pure) and packages/brd14-wasm (wasm).
# Node and Bun come from scripts/env.sh (the root Makefile sources it).
#
#   make test        typecheck + the grep gate + vitest on Node + bun test on Bun
#   make bench       mitata on Node and Bun, pinned to one core → ../bench/results/
#   make harden      strict typecheck, grep gate, the shims under --frozen-intrinsics
#   make build       tsc emit of both packages → dist/ (+ the publish manifests)
#   make conform     what tools/parity.py needs: dependencies installed, the wasm module embedded
#   make wasm-bytes  packages/brd14-wasm/src/wasm-bytes.ts from the Rust crate (cargo, wasm32)
#   make clean
SHELL   := /bin/bash
NPM     ?= npm
NODE    ?= node
BUN     ?= bun
NPX     := $(NPM) exec --
TASKSET := $(shell command -v taskset >/dev/null 2>&1 && echo "taskset -c 2")

# The embedded wasm module (generated, gitignored). Rebuilt when the Rust sources of
# the wasm crate or the core, or the build script, are newer than it.
WASM_BYTES := packages/brd14-wasm/src/wasm-bytes.ts
CRATES     := ../native/rust/crates
WASM_DEPS  := packages/brd14-wasm/scripts/build-wasm.ts \
              $(wildcard $(CRATES)/brd14-wasm/src/*.rs $(CRATES)/brd14-wasm/build.rs $(CRATES)/brd14-wasm/Cargo.toml) \
              $(wildcard $(CRATES)/brd14/src/*.rs $(CRATES)/brd14/Cargo.toml)

# Dependencies are installed when node_modules/ is missing, never re-resolved.
deps:
	@test -d node_modules || $(NPM) ci --no-audit --no-fund

$(WASM_BYTES): $(WASM_DEPS)
	$(NODE) packages/brd14-wasm/scripts/build-wasm.ts

wasm-bytes: $(WASM_BYTES)

typecheck: deps wasm-bytes
	$(NPX) tsc -p tsconfig.json

# Test files may import only { describe, test, expect } from "vitest" (Bun maps
# that module to bun:test). Mocks and runner-specific modules would break one runtime.
lint-tests:
	@! grep -rnE '\bvi\.' packages/*/test --include='*.ts' || { echo "tests must not use vi.*"; exit 1; }
	@! grep -rn 'bun:test' packages/*/test --include='*.ts' || { echo "tests must import from vitest, not bun:test"; exit 1; }

test: typecheck lint-tests
	$(NPX) vitest run
	$(BUN) test ./packages

bench: deps wasm-bytes
	$(TASKSET) $(NODE) bench/pure.ts
	$(TASKSET) $(BUN) bench/pure.ts

harden: typecheck lint-tests
	$(NODE) --frozen-intrinsics --disable-proto=throw conform/pure.ts < conform/smoke.req | diff - conform/smoke.resp
	$(BUN) conform/pure.ts < conform/smoke.req | diff - conform/smoke.resp

build: deps wasm-bytes
	$(NPX) tsc -p packages/brd14/tsconfig.json
	$(NODE) scripts/publish-manifest.ts packages/brd14
	$(NPX) tsc -p packages/brd14-wasm/tsconfig.json
	$(NODE) scripts/publish-manifest.ts packages/brd14-wasm
	$(NODE) packages/brd14-wasm/scripts/publish-deps.ts packages/brd14-wasm

conform: deps wasm-bytes

clean:
	rm -rf node_modules packages/*/dist packages/*/node_modules $(WASM_BYTES)

.PHONY: deps wasm-bytes typecheck lint-tests test bench harden build conform clean
