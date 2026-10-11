# brd14 — polyglot monorepo. Each tree owns a Makefile with the same targets;
# this one delegates, sets the shared environment, and adds the cross-language
# targets (vectors, parity).
#
#   make test      every language suite, against vectors/ (required here)
#   make parity    differential run: every shim vs the oracle (tools/parity.py)
#   make bench     every bench, results under bench/results/
#   make harden    sanitizers, Miri, race detector, floor toolchains
#   make vectors   regenerate vectors/ and fail if they drifted
SHELL   := /bin/bash
TREES   := $(patsubst %/Makefile,%,$(wildcard go/Makefile native/Makefile python/Makefile ts/Makefile))
ENV     := . scripts/env.sh &&
export BRD14_REQUIRE_VECTORS := 1

test bench harden clean:
	@for d in $(TREES); do echo "== $$d: $@"; $(ENV) $(MAKE) -C $$d $@ || exit 1; done

vectors:
	python3 tools/vectorgen.py
	git diff --exit-code -- vectors/

parity:
	$(ENV) python3 tools/parity.py

setup:
	scripts/setup.sh core

.PHONY: test bench harden clean vectors parity setup
