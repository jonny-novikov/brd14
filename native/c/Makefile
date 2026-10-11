# native/c — the C cores. Variants live in sibling folders and share one ABI
# header (../include/branded_id.h); every target here builds each variant.
#
#   make            both cores: build/<variant>/branded_id.o
#   make test       vectors per core + the cross-core property suite
#   make conform    parity shims build/conform-{speed,memory}
#   make bench      bench/README.md protocol, JSON into ../../bench/results/
#   make gates      object code: no div, no allocator, footprint (gates.sh)
#   make fuzz       libFuzzer + ASan + UBSan, FUZZ_SECONDS per target (default 30)
#   make fuzz-cov   per-core source coverage from the fuzz corpora (llvm-cov)
#   make harden     sanitizers, fortify, conversion warnings, clang build
#   make clean
#
# Per-variant optimisation: the speed core is built for cycles (-O2), the
# memory core for footprint (-Os). Override with OPT_speed=... OPT_memory=...
# and add flags to every compile and link with EXTRA_CFLAGS=...
ifeq ($(origin CC),default)
CC := gcc
endif
OBJCOPY ?= objcopy

VARIANTS     := speed memory
OPT_speed    ?= -O2
OPT_memory   ?= -Os
WARN         := -std=c11 -Wall -Wextra -Werror
CORE_CFLAGS  := $(WARN) -fPIC
EXTRA_CFLAGS ?=
INC          := -I../include
HDR          := ../include/branded_id.h
BUILD        ?= build
VECTORS      ?= $(abspath ../../vectors)

CORES := $(VARIANTS:%=$(BUILD)/%/branded_id.o)

all: $(CORES)

$(BUILD)/%/branded_id.o: %/branded_id.c $(HDR)
	@mkdir -p $(dir $@)
	$(CC) $(CORE_CFLAGS) $(OPT_$*) $(EXTRA_CFLAGS) $(INC) -c $< -o $@

# ── tests ────────────────────────────────────────────────────────────────
# A test-only third build of the memory source: the portable 32-bit-limb
# mulhi path (BRANDED_NO_INT128), which no shipped build here exercises.
$(BUILD)/memory-noint128/branded_id.o: memory/branded_id.c $(HDR)
	@mkdir -p $(dir $@)
	$(CC) $(CORE_CFLAGS) $(OPT_memory) -DBRANDED_NO_INT128 $(EXTRA_CFLAGS) $(INC) -c $< -o $@

# The same object with its four ABI symbols renamed <variant>_branded_*, so
# several cores link into one differential binary and the code under test
# is byte-for-byte the code that ships.
ABI_SYMS := branded_encode branded_decode branded_hash32 branded_unix_ms
$(BUILD)/%/branded_id.ren.o: $(BUILD)/%/branded_id.o
	$(OBJCOPY) $(foreach s,$(ABI_SYMS),--redefine-sym $(s)=$(subst -,_,$*)_$(s)) $< $@

TEST_VARIANTS := speed memory memory-noint128
TEST_OPT      ?= -O2
TEST_CFLAGS    = $(WARN) $(TEST_OPT) $(EXTRA_CFLAGS) $(INC)
TEST_HDRS     := test/support.h test/cores.h $(HDR)
PROP_N        ?= 10000000

$(BUILD)/test_vectors-%: test/test_vectors.c $(TEST_HDRS) $(BUILD)/%/branded_id.o
	$(CC) $(TEST_CFLAGS) -DVARIANT='"$*"' $< $(BUILD)/$*/branded_id.o -o $@

$(BUILD)/test_props: test/test_props.c $(TEST_HDRS) $(TEST_VARIANTS:%=$(BUILD)/%/branded_id.ren.o)
	$(CC) $(TEST_CFLAGS) $< $(filter %.ren.o,$^) -o $@

test: all $(TEST_VARIANTS:%=$(BUILD)/test_vectors-%) $(BUILD)/test_props
	@for v in $(TEST_VARIANTS); do $(BUILD)/test_vectors-$$v $(VECTORS) || exit 1; done
	@$(BUILD)/test_props $(PROP_N)

# ── parity shims (tools/parity.py runs `make -s conform`) ────────────────
$(BUILD)/conform-%: test/conform.c $(TEST_HDRS) $(BUILD)/%/branded_id.o
	$(CC) $(TEST_CFLAGS) -DVARIANT='"$*"' $< $(BUILD)/$*/branded_id.o -o $@

conform: $(VARIANTS:%=$(BUILD)/conform-%)

# ── bench (bench/README.md protocol; results are not committed) ──────────
RESULTS ?= $(abspath ../../bench/results)
# Pin to CPU 2 when taskset exists and that CPU is usable; otherwise run
# unpinned (the JSON records which, from the process's real affinity).
TASKSET ?= $(shell taskset -c 2 true >/dev/null 2>&1 && echo taskset -c 2)

$(BUILD)/bench-%: bench/bench.c $(TEST_HDRS) $(BUILD)/%/branded_id.o
	$(CC) $(TEST_CFLAGS) -DVARIANT='"$*"' -DCORE_CFLAGS='"$(strip $(OPT_$*) $(EXTRA_CFLAGS))"' \
	    $< $(BUILD)/$*/branded_id.o -lm -o $@

bench: $(VARIANTS:%=$(BUILD)/bench-%)
	@mkdir -p $(RESULTS)
	@for v in $(VARIANTS); do $(TASKSET) $(BUILD)/bench-$$v $(VECTORS) $(RESULTS) || exit 1; done

# ── object-code gates: no div, no allocator, footprint (gates.sh) ────────
gates: all
	@CC='$(CC)' sh gates.sh $(BUILD) $(VARIANTS)

# ── fuzzing: libFuzzer + ASan + UBSan (clang) ────────────────────────────
# Every core links into each target (renamed objects, as for test_props);
# the cores are built at their shipped -O level with fuzzer coverage.
FUZZ_CC      ?= clang
FUZZ_BUILD   := build/fuzz
FUZZ_FLAGS   := -g -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=all
FUZZ_SECONDS ?= 30
FUZZ_TARGETS := fuzz_decode fuzz_encode
FUZZ_CORES   := speed memory memory-noint128

$(BUILD)/fuzz_%: fuzz/fuzz_%.c $(TEST_HDRS) $(FUZZ_CORES:%=$(BUILD)/%/branded_id.ren.o)
	$(CC) $(TEST_CFLAGS) -fsanitize=fuzzer $< $(filter %.ren.o,$^) -o $@

fuzz-build:
	@$(MAKE) -s BUILD=$(FUZZ_BUILD) CC=$(FUZZ_CC) EXTRA_CFLAGS='$(FUZZ_FLAGS)' $(FUZZ_TARGETS:%=$(FUZZ_BUILD)/%)

# Corpora live in fuzz/corpus/<target> (ignored by git); the decode corpus is
# seeded with the first 64 ids of vectors/valid.tsv when present. A crash is
# written to fuzz/crash-<sha1> and fails the target.
fuzz: fuzz-build
	@set -e; for t in $(FUZZ_TARGETS); do \
	  mkdir -p fuzz/corpus/$$t; \
	  if [ $$t = fuzz_decode ] && [ -f $(VECTORS)/valid.tsv ] && [ -z "$$(ls fuzz/corpus/$$t)" ]; then \
	    LC_ALL=C awk -F'\t' '!/^#/ && n < 64 { f = "fuzz/corpus/fuzz_decode/seed-" n++; printf "%s", $$3 > f; close(f) }' \
	      $(VECTORS)/valid.tsv; \
	  fi; \
	  case $$t in fuzz_decode) maxlen=64 ;; *) maxlen=16 ;; esac; \
	  echo "== fuzz $$t: $(FUZZ_SECONDS) s"; \
	  rc=0; $(FUZZ_BUILD)/$$t -max_total_time=$(FUZZ_SECONDS) -max_len=$$maxlen -print_final_stats=1 \
	    -dict=fuzz/brd14.dict -artifact_prefix=fuzz/ fuzz/corpus/$$t > $(FUZZ_BUILD)/$$t.log 2>&1 || rc=$$?; \
	  grep -E '^#[0-9]+[[:space:]]+(INITED|DONE)|^stat::(number_of_executed_units|average_exec_per_sec|new_units_added|peak_rss_mb)|ERROR|SUMMARY' \
	    $(FUZZ_BUILD)/$$t.log | sed 's/^/  /'; \
	  if [ $$rc -ne 0 ]; then tail -40 $(FUZZ_BUILD)/$$t.log; exit $$rc; fi; \
	done

# Source coverage of each core from the corpora `make fuzz` grew.
fuzz-cov:
	@CLANG='$(FUZZ_CC)' sh fuzz/fuzzcov.sh build fuzz/corpus

# ── hardening ────────────────────────────────────────────────────────────
# 1. the full test suite under ASan + UBSan, any report fatal;
# 2. again with _FORTIFY_SOURCE=3 and the strong stack protector;
# 3. -Wconversion -Wsign-conversion -Wpedantic as errors, gcc and clang, every
#    source (overlength-strings excepted: the speed core's 7,688-char pair
#    table is past C's 4,095-char minimum translation limit, which gcc, clang
#    and MSVC all exceed);
# 4. the test suite built by clang.
SAN_FLAGS     := -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all
FORTIFY_FLAGS := -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fstack-protector-strong
CONV_FLAGS    := -Wconversion -Wsign-conversion -Wpedantic -Wno-overlength-strings
ALL_SRCS      := speed/branded_id.c memory/branded_id.c test/test_vectors.c test/test_props.c \
                 test/conform.c bench/bench.c fuzz/fuzz_decode.c fuzz/fuzz_encode.c

harden:
	@echo "== c harden: ASan + UBSan, -fno-sanitize-recover=all ($(CC))"
	@$(MAKE) -s BUILD=build/asan EXTRA_CFLAGS='$(SAN_FLAGS)' test
	@echo "== c harden: -D_FORTIFY_SOURCE=3 -fstack-protector-strong ($(CC))"
	@$(MAKE) -s BUILD=build/fortify EXTRA_CFLAGS='$(FORTIFY_FLAGS)' test
	@echo "== c harden: $(CONV_FLAGS) -Werror"
	@for cc in $(CC) clang; do \
	  for f in $(ALL_SRCS); do $$cc $(WARN) $(CONV_FLAGS) $(INC) -fsyntax-only $$f || exit 1; done; \
	  echo "ok   $$cc: $(words $(ALL_SRCS)) sources clean"; \
	done
	@echo "== c harden: the test suite built by clang"
	@$(MAKE) -s BUILD=build/clang CC=clang test

clean:
	rm -rf build

.SECONDARY:
.PHONY: all test conform bench gates fuzz fuzz-build fuzz-cov harden clean
