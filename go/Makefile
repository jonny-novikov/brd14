# go/ — the reference implementation. GOTOOLCHAIN comes from scripts/env.sh.
#
#   make test      vet + the full suite (vectors/ required when BRD14_REQUIRE_VECTORS=1)
#   make conform   the parity shim, at the path tools/parity.py runs
#   make bench     bench/README.md protocol -> ../bench/results/go-reference-<go version>.json
#   make harden    vet, -race, the go1.22 floor toolchain, native fuzzing
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -ec

GO       ?= go
# The go.mod floor, as scripts/versions.env pins it (GO_FLOOR_VERSION).
GO_FLOOR ?= go1.22.12
FUZZTIME ?= 10s

SHIM    := ../build/shims/go-conform
GOVER    = $(shell $(GO) env GOVERSION)
RESULTS := ../bench/results
# One core, when the machine has a third one to pin to; the JSON records which.
PIN     := $(shell taskset -c 2 true >/dev/null 2>&1 && echo taskset -c 2)
CORPUS  := $(if $(wildcard ../vectors/valid.tsv),vectors/valid.tsv rows 1..4096,splitmix64 seed 0xb4d140001 regenerated in-test (= vectors/valid.tsv rows 1..4096))

test:
	$(GO) vet ./...
	$(GO) test -count=1 ./...

conform:
	@mkdir -p $(dir $(SHIM))
	$(GO) build -o $(SHIM) ./internal/conform

# Ten samples of every benchmark, each a full -benchtime (1 s), pinned. The raw
# output stays in bench.out (benchstat reads it); internal/benchjson reduces it
# to the shared schema: median ns/op, MAD, CV, allocs/op, B/op.
bench:
	@mkdir -p $(RESULTS)
	$(PIN) $(GO) test -run '^$$' -bench . -benchmem -count 10 . | tee bench.out
	$(GO) run ./internal/benchjson -runtime $(GOVER) -pinned=$(if $(PIN),true,false) \
		-corpus '$(CORPUS)' -o $(RESULTS)/go-reference-$(GOVER).json < bench.out

# vet; the race detector (the generator's CAS cell is the shared state); the
# whole suite on the go.mod floor toolchain, proving `go 1.22.0` is honest;
# then each native fuzz target for FUZZTIME against its contract model.
harden:
	$(GO) vet ./...
	$(GO) test -race -count=1 ./...
	GOTOOLCHAIN=$(GO_FLOOR) $(GO) test -count=1 ./...
	$(GO) test -run '^$$' -fuzz '^FuzzParse$$' -fuzztime $(FUZZTIME) .
	$(GO) test -run '^$$' -fuzz '^FuzzAppendEncode$$' -fuzztime $(FUZZTIME) .

clean:
	$(GO) clean -testcache
	rm -f $(SHIM) bench.out

.PHONY: test conform bench harden clean
