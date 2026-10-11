# go/ — the reference implementation. GOTOOLCHAIN comes from scripts/env.sh.
GO ?= go

test:
	$(GO) vet ./...
	$(GO) test -count=1 ./...
bench:
	@echo "go: benches land in W2a"
harden:
	$(GO) test -race -count=1 ./...
clean:
	$(GO) clean -testcache

.PHONY: test bench harden clean
