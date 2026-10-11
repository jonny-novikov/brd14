# ts/ — the TypeScript workspace: packages/brd14 (pure) and, later, packages/brd14-wasm.
# Node and Bun come from scripts/env.sh (the root Makefile sources it).
#
#   make test      typecheck + the grep gate + vitest on Node + bun test on Bun
#   make bench     mitata on Node and Bun, pinned to one core → ../bench/results/
#   make harden    strict typecheck, grep gate, the shim under --frozen-intrinsics
#   make build     tsc emit of packages/brd14 → dist/ (+ the publish manifest)
#   make conform   what tools/parity.py needs: dependencies installed
#   make clean
SHELL   := /bin/bash
NPM     ?= npm
NODE    ?= node
BUN     ?= bun
NPX     := $(NPM) exec --
TASKSET := $(shell command -v taskset >/dev/null 2>&1 && echo "taskset -c 2")

# Dependencies are installed when node_modules/ is missing, never re-resolved.
deps:
	@test -d node_modules || $(NPM) ci --no-audit --no-fund

typecheck: deps
	$(NPX) tsc -p tsconfig.json

# Test files may import only { describe, test, expect } from "vitest" (Bun maps
# that module to bun:test). Mocks and runner-specific modules would break one runtime.
lint-tests:
	@! grep -rnE '\bvi\.' packages/*/test --include='*.ts' || { echo "tests must not use vi.*"; exit 1; }
	@! grep -rn 'bun:test' packages/*/test --include='*.ts' || { echo "tests must import from vitest, not bun:test"; exit 1; }

test: typecheck lint-tests
	$(NPX) vitest run
	$(BUN) test ./packages

bench: deps
	$(TASKSET) $(NODE) bench/pure.ts
	$(TASKSET) $(BUN) bench/pure.ts

harden: typecheck lint-tests
	$(NODE) --frozen-intrinsics --disable-proto=throw conform/pure.ts < conform/smoke.req | diff - conform/smoke.resp
	$(BUN) conform/pure.ts < conform/smoke.req | diff - conform/smoke.resp

build: deps
	$(NPX) tsc -p packages/brd14/tsconfig.json
	$(NODE) scripts/publish-manifest.ts packages/brd14

conform: deps

clean:
	rm -rf node_modules packages/*/dist packages/*/node_modules

.PHONY: deps typecheck lint-tests test bench harden build conform clean
