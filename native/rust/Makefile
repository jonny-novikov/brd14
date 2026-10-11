# native/rust — thin make façade over cargo so the root Makefile can delegate.
#
#   make all         release build of the workspace (host) and the wasm module
#   make test        the workspace suites, the C drop-in check, the wasm ABI check
#   make ffi         libbrd14_ffi.so / .a (speed core; FFI_FEATURES=--features=memory for memory)
#   make conform     the parity shim, target/release/brd14-conform speed|memory
#   make wasm        target/wasm32-unknown-unknown/release/brd14_wasm.wasm (speed core;
#                    WASM_FEATURES=--features=memory for the memory core)
#   make wasm-check  both cores built side by side, verified through node (ABI + vectors)
CARGO ?= cargo
NODE  ?= node

# Work without `. scripts/env.sh` too (tools/parity.py calls `make conform` directly).
ifeq ($(shell command -v $(CARGO) 2>/dev/null),)
export PATH := $(HOME)/.cargo/bin:/opt/node24/bin:$(PATH)
endif

FFI_FEATURES  ?=
WASM_FEATURES ?=
CC ?= cc
REL := target/release
WASM_TARGET := wasm32-unknown-unknown
WASM_OUT := target/$(WASM_TARGET)/release/brd14_wasm.wasm
CORES := target/wasm-cores

all:
	$(CARGO) build --release --workspace
	$(MAKE) --no-print-directory wasm

test: ffi-check wasm-check
	$(CARGO) test --workspace
	$(CARGO) test -p brd14 --features std
	$(CARGO) test -p brd14-ffi --features memory
	$(CARGO) test -p brd14-wasm --features memory

ffi:
	$(CARGO) build --release -p brd14-ffi $(FFI_FEATURES)

# The parity shim: target/release/brd14-conform speed|memory (tools/parity.py runs it).
conform:
	$(CARGO) build --release -p brd14-conform

# The drop-in proof: a C program built against the unchanged branded_id.h, linked once
# against the static archive and once against the shared object — for each core. The
# speed build runs last, so it is the libbrd14_ffi left in target/release.
ffi-check:
	$(MAKE) --no-print-directory ffi dropin FFI_FEATURES=--features=memory
	$(MAKE) --no-print-directory ffi dropin

dropin:
	@mkdir -p target/dropin
	$(CC) -O2 -Wall -Wextra -Werror -std=c11 -I../include -o target/dropin/static \
	    crates/brd14-ffi/c/dropin.c $(REL)/libbrd14_ffi.a
	$(CC) -O2 -Wall -Wextra -Werror -std=c11 -I../include -o target/dropin/shared \
	    crates/brd14-ffi/c/dropin.c -L$(REL) -lbrd14_ffi -Wl,-rpath,'$$ORIGIN/../release'
	target/dropin/static
	target/dropin/shared

wasm:
	$(CARGO) build --release -p brd14-wasm --target $(WASM_TARGET) $(WASM_FEATURES)
	@echo "wasm: $(WASM_OUT) ($$(wc -c < $(WASM_OUT)) bytes)"

# Both cores side by side in target/wasm-cores/; the speed build runs last, so the
# default module is the one left at $(WASM_OUT).
wasm-cores:
	@mkdir -p $(CORES)
	$(MAKE) --no-print-directory wasm WASM_FEATURES=--features=memory
	cp $(WASM_OUT) $(CORES)/brd14_wasm-memory.wasm
	$(MAKE) --no-print-directory wasm
	cp $(WASM_OUT) $(CORES)/brd14_wasm-speed.wasm

wasm-check: wasm-cores
	@if command -v $(NODE) >/dev/null 2>&1; then \
	    $(NODE) crates/brd14-wasm/check.mjs $(CORES)/brd14_wasm-speed.wasm $(CORES)/brd14_wasm-memory.wasm; \
	else echo "wasm-check: SKIP ($(NODE) not found)"; fi

# bench/README.md: pinned to one core when taskset exists; JSON into ../../bench/results/.
TASKSET := $(shell command -v taskset >/dev/null 2>&1 && echo taskset -c 2)
BENCH := $(CARGO) bench -p brd14 --features std --bench codec

bench:
	$(BENCH) --no-run
	$(TASKSET) $(BENCH)

# Hardening: lints and formatting, the no-allocator proof, Miri, and the fuzzers.
NIGHTLY := $(CARGO) +nightly
FUZZ_SECONDS ?= 30
BOTH_MEMORY := --features brd14-ffi/memory,brd14-wasm/memory
ALLOC_SYMS := '\b(malloc|calloc|realloc|free|posix_memalign|aligned_alloc|__rust_alloc|__rust_dealloc|__rust_realloc)\b'

harden: clippy alloc-check miri fuzz

clippy:
	$(CARGO) fmt --all --check
	$(CARGO) fmt --manifest-path fuzz/Cargo.toml --check
	$(CARGO) clippy --workspace --all-targets -- -D warnings
	$(CARGO) clippy -p brd14 --all-targets --features std -- -D warnings
	$(CARGO) clippy -p brd14-ffi -p brd14-wasm --all-targets $(BOTH_MEMORY) -- -D warnings
	$(CARGO) clippy -p brd14-wasm --target $(WASM_TARGET) -- -D warnings

# Zero allocation, by construction and by inspection: the ffi library imports no allocator.
alloc-check: ffi
	@if nm -u $(REL)/libbrd14_ffi.so | grep -Eq $(ALLOC_SYMS); then \
	    echo "alloc-check: libbrd14_ffi.so imports an allocator"; nm -u $(REL)/libbrd14_ffi.so; exit 1; fi
	@if nm -u $(REL)/libbrd14_ffi.a 2>/dev/null | grep -Eq $(ALLOC_SYMS); then \
	    echo "alloc-check: libbrd14_ffi.a references an allocator"; exit 1; fi
	@echo "alloc-check: ok — nm -u libbrd14_ffi.so: $$(nm -u $(REL)/libbrd14_ffi.so | awk '{print $$NF}' | tr '\n' ' ')"

# Miri: the core with isolation off (it reads vectors/, the wall clock and the host name),
# the two crates with unsafe code under strict provenance, for both cores.
miri:
	MIRIFLAGS=-Zmiri-disable-isolation $(NIGHTLY) miri test -p brd14
	MIRIFLAGS=-Zmiri-strict-provenance $(NIGHTLY) miri test -p brd14-ffi -p brd14-wasm
	MIRIFLAGS=-Zmiri-strict-provenance $(NIGHTLY) miri test -p brd14-ffi -p brd14-wasm $(BOTH_MEMORY)

# libFuzzer differential targets (nightly, ASan), seeded from the corpus ids when present.
fuzz:
	@mkdir -p fuzz/corpus/decode_differential
	@if [ -f ../../vectors/valid.tsv ]; then \
	    grep -v '^#' ../../vectors/valid.tsv | head -64 | cut -f3 | while read -r id; do \
	        printf '%s' "$$id" > "fuzz/corpus/decode_differential/seed-$$id"; done; fi
	$(NIGHTLY) fuzz run --fuzz-dir fuzz decode_differential -- -max_total_time=$(FUZZ_SECONDS)
	$(NIGHTLY) fuzz run --fuzz-dir fuzz encode_differential -- -max_total_time=$(FUZZ_SECONDS)

clean:
	$(CARGO) clean
	rm -rf fuzz/target

.PHONY: all test ffi ffi-check dropin conform wasm wasm-cores wasm-check bench
.PHONY: harden clippy alloc-check miri fuzz clean
