# native/beam — the Erlang NIF (Elixir.EchoData.Native) over one brd14 core.
#
# This folder ships inside native/ and is vendored into an Elixir app as its
# native/ directory, next to the app's priv/; hence PRIV ?= ../../priv.
#
#   make                  CORE=rust (default): link the Rust FFI drop-in
#   make CORE=c-speed     compile the C speed core into the NIF  (-O2)
#   make CORE=c-memory    compile the C memory core into the NIF (-Os)
#   make check            compile-check echo_native.c (real ERTS headers when
#                         found, else stub/erl_nif.h) and link-check the NIF
#                         against each core available here
#   make clean
#
# CORE=rust builds the brd14-ffi crate (`cargo build --release -p brd14-ffi`
# in ../rust), copies target/release/libbrd14_ffi.so into PRIV, and links the
# NIF against it with rpath $ORIGIN, so the loader finds the library next to
# echo_native.so wherever the release puts priv/. The c-* cores are compiled
# into echo_native.so itself: one file, no runtime dependency.
ifeq ($(origin CC),default)
CC := gcc
endif
PRIV    ?= ../../priv
CORE    ?= rust
CARGO   ?= cargo
ERL     ?= erl
WARN    := -std=c11 -Wall -Wextra -Werror
CFLAGS  ?= -O2
INC     := -I../include
HDR     := ../include/branded_id.h
BUILD   := build
NIF     := $(PRIV)/echo_native.so

RUST_DIR := ../rust
RUST_LIB := $(RUST_DIR)/target/release/libbrd14_ffi.so

C_SRC_c-speed  := ../c/speed/branded_id.c
C_SRC_c-memory := ../c/memory/branded_id.c
C_OPT_c-speed  := -O2
C_OPT_c-memory := -Os

ifeq ($(filter $(CORE),rust c-speed c-memory),)
$(error CORE must be one of: rust c-speed c-memory (got '$(CORE)'))
endif

# The ERTS include directory of the erl on PATH (or set ERTS_INCLUDE=...).
ifeq ($(origin ERTS_INCLUDE),undefined)
ERTS_INCLUDE := $(shell command -v $(ERL) >/dev/null 2>&1 && $(ERL) -noshell -eval \
  'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)
endif
HAVE_ERTS := $(if $(wildcard $(ERTS_INCLUDE)/erl_nif.h),yes,)

all: $(NIF)

# Rebuild the NIF when CORE changes: the stamp's content is the core name.
$(BUILD)/core.stamp: FORCE
	@mkdir -p $(BUILD)
	@echo '$(CORE)' | cmp -s - $@ || echo '$(CORE)' > $@

need-erts:
	@if [ -z "$(HAVE_ERTS)" ]; then \
	  echo "beam: ERTS headers not found (no erl on PATH, or set ERTS_INCLUDE=<erts>/include)."; \
	  echo "      'make check' compiles against a stub instead, but a loadable NIF needs real headers."; \
	  exit 1; \
	fi

ifeq ($(CORE),rust)
$(RUST_LIB): FORCE
	cd $(RUST_DIR) && $(CARGO) build --release -p brd14-ffi

$(PRIV)/libbrd14_ffi.so: $(RUST_LIB)
	@mkdir -p $(PRIV)
	cp $< $@

$(NIF): echo_native.c $(HDR) $(BUILD)/core.stamp $(PRIV)/libbrd14_ffi.so | need-erts
	$(CC) $(WARN) $(CFLAGS) -fPIC -shared -isystem "$(ERTS_INCLUDE)" $(INC) -o $@ echo_native.c \
	    -L$(PRIV) -lbrd14_ffi -Wl,-rpath,'$$ORIGIN'
else
# -fvisibility=hidden: the core's branded_* symbols bind inside the NIF and
# are not re-exported, so echo_native.so exports nif_init alone and cannot
# interpose on (or be interposed by) another library carrying the same ABI.
$(BUILD)/$(CORE).o: $(C_SRC_$(CORE)) $(HDR)
	@mkdir -p $(BUILD)
	$(CC) $(WARN) $(C_OPT_$(CORE)) -fPIC -fvisibility=hidden $(INC) -c $< -o $@

$(NIF): echo_native.c $(HDR) $(BUILD)/core.stamp $(BUILD)/$(CORE).o | need-erts
	@mkdir -p $(PRIV)
	rm -f $(PRIV)/libbrd14_ffi.so
	$(CC) $(WARN) $(CFLAGS) -fPIC -shared -isystem "$(ERTS_INCLUDE)" $(INC) -o $@ echo_native.c $(BUILD)/$(CORE).o
endif

# ── check: works with or without Erlang installed ────────────────────────
# Without ERTS, stub/erl_nif.h (marked CI-only) stands in, and the link check
# builds throwaway .so files under build/check/ that are never loaded: it
# proves each core satisfies every branded_* reference, so the only symbols
# left undefined are the enif_* ones ERTS provides (plus libc's). For the rust
# core the branded_* symbols are resolved at load time from libbrd14_ffi.so:
# the check proves the NIF records it as NEEDED and that it defines each one.
CHECK_INC = $(if $(HAVE_ERTS),-isystem "$(ERTS_INCLUDE)",-Istub)
CHECK_HDR = $(if $(HAVE_ERTS),ERTS headers in $(ERTS_INCLUDE),stub/erl_nif.h (no ERTS here; syntax check only))

check:
	@$(CC) $(WARN) $(CFLAGS) -fsyntax-only $(CHECK_INC) $(INC) echo_native.c
	@echo "ok   beam: echo_native.c compiles against $(CHECK_HDR)"
	@mkdir -p $(BUILD)/check
	@for core in c-speed c-memory rust; do \
	  case $$core in \
	    c-speed)  src=$(C_SRC_c-speed);  opt=$(C_OPT_c-speed);  link=""; provider="" ;; \
	    c-memory) src=$(C_SRC_c-memory); opt=$(C_OPT_c-memory); link=""; provider="" ;; \
	    rust)     if [ ! -f $(RUST_LIB) ]; then echo "skip beam: $$core link check ($(RUST_LIB) not built)"; continue; fi; \
	              src=""; link="-L$(dir $(RUST_LIB)) -lbrd14_ffi"; provider=$(RUST_LIB) ;; \
	  esac; \
	  obj=""; \
	  if [ -n "$$src" ]; then obj=$(BUILD)/check/$$core.o; $(CC) $(WARN) $$opt -fPIC -fvisibility=hidden $(INC) -c $$src -o $$obj || exit 1; fi; \
	  so=$(BUILD)/check/echo_native-$$core.so; \
	  $(CC) $(WARN) $(CFLAGS) -fPIC -shared $(CHECK_INC) $(INC) -o $$so echo_native.c $$obj $$link || exit 1; \
	  undef=$$(nm -D --undefined-only $$so | awk '{print $$NF}' | grep -v '^enif_' | grep -vE '^(memcpy|memcmp|__cxa_finalize|_ITM_|__gmon_start__|__stack_chk_fail)' || true); \
	  if [ -n "$$provider" ]; then \
	    readelf -d $$so | grep -q 'NEEDED.*libbrd14_ffi.so' || { echo "FAIL beam: $$core NIF does not record NEEDED libbrd14_ffi.so"; exit 1; }; \
	    provided=$$(nm -D --defined-only $$provider | awk '{print $$NF}'); \
	    undef=$$(for s in $$undef; do echo "$$provided" | grep -qx "$$s" || echo "$$s"; done); \
	  fi; \
	  if [ -n "$$undef" ]; then echo "FAIL beam: $$core leaves unexpected undefined symbols: $$undef"; exit 1; fi; \
	  nm -D --defined-only $$so | grep -q ' T nif_init$$' || { echo "FAIL beam: $$core: nif_init not exported"; exit 1; }; \
	  echo "ok   beam: NIF links against $$core ($$(nm -D --undefined-only $$so | grep -c ' enif_') enif_* left for ERTS)"; \
	done

test: check

clean:
	rm -f $(NIF) $(PRIV)/libbrd14_ffi.so
	rm -rf $(BUILD)

FORCE:
.PHONY: all check test clean need-erts FORCE
