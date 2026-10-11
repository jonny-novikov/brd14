# python/: the pure-Python brd14 package.
#
#   make venv      one venv per available interpreter (.venv-3.14, .venv-3.14t, .venv-3.12, .venv-3.13)
#                  with the dev tools: pytest, pyperf, mypy. The package itself is stdlib-only.
#   make test      pytest on every venv; the free-threaded one with the GIL forced off
#   make bench     bench/bench.py on 3.14 and 3.14t -> ../bench/results/python-pure-<runtime>.json
#   make harden    3.14t: the suite under -X dev -W error with PYTHON_GIL=0 -X gil=0, then the
#                  thread stress tests repeated; 3.14 under -X dev -W error; mypy --strict
#   make threads   multi-thread mint throughput, 3.14 vs 3.14t (printed, not written)
#   make parity    tools/parity.py for the python shims
#   make conform   nothing to build: the shim is python/conform.py
#   make clean     venvs and caches
SHELL          := /bin/bash
VERSIONS       ?= 3.14 3.14t 3.12 3.13
BENCH_VERSIONS ?= 3.14 3.14t
BENCH_ARGS     ?= --fast
STRESS_ROUNDS  ?= 5
DEV_DEPS       := pytest pyperf mypy
AVAILABLE      := $(foreach v,$(VERSIONS),$(if $(shell command -v python$(v) 2>/dev/null),$(v)))

# py VERSION ARGS...: run a venv's interpreter; a free-threaded one (suffix t) with the GIL off.
PY := py() { local v=$$1; shift; case $$v in \
        *t) PYTHON_GIL=0 .venv-$$v/bin/python -X gil=0 "$$@" ;; \
        *)  .venv-$$v/bin/python "$$@" ;; esac; }

venv: $(foreach v,$(AVAILABLE),.venv-$(v)/.ok)

.venv-%/.ok: Makefile
	python$* -m venv --clear .venv-$*
	.venv-$*/bin/python -m pip install -q --disable-pip-version-check $(DEV_DEPS)
	@touch $@

test: venv
	@$(PY); set -e; for v in $(AVAILABLE); do echo "== pytest: python$$v"; py $$v -m pytest -q; done

bench: venv
	@$(PY); set -e; for v in $(BENCH_VERSIONS); do echo "== bench: python$$v"; py $$v bench/bench.py $(BENCH_ARGS); done

harden: venv
	@command -v python3.14t >/dev/null || { echo "harden: python3.14t is required"; exit 1; }
	@$(PY); set -e; \
	echo "== 3.14t: full suite, -X dev -W error, GIL off"; \
	py 3.14t -X dev -W error -m pytest -q; \
	for i in $$(seq $(STRESS_ROUNDS)); do \
	  echo "== 3.14t: stress round $$i/$(STRESS_ROUNDS)"; py 3.14t -X dev -W error -m pytest -q -m stress -p no:cacheprovider; \
	done; \
	echo "== 3.14: full suite, -X dev -W error"; py 3.14 -X dev -W error -m pytest -q; \
	echo "== mypy --strict"; .venv-3.14/bin/mypy --strict

threads: venv
	@$(PY); set -e; for v in $(BENCH_VERSIONS); do py $$v bench/threads.py; done

parity:
	cd .. && python3 tools/parity.py --only python

conform:
	@:

clean:
	rm -rf .venv-* .pytest_cache .mypy_cache build dist
	find . -name __pycache__ -type d -prune -exec rm -rf {} +

.PHONY: venv test bench harden threads parity conform clean
