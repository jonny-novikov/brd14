# ex/: the Elixir home — echo_data, standalone (Elixir >= 1.14, OTP >= 25).
#
#   make test      compile --warnings-as-errors, then the ExUnit suite (doctests, properties)
#   make bench     the structures bench -> ../bench/results/elixir-*.json
#   make harden    format check, no compile-time cycles (xref), the suite under a fixed seed
#   make conform   compile the parity shim's dependencies (shims ex-pure / ex-nif)
#   make clean     _build and deps
SHELL := /bin/bash
APP   := echo_data
MIX   := cd $(APP) && TMPDIR=/tmp MIX_ENV
SEED  ?= 0

deps:
	cd $(APP) && TMPDIR=/tmp mix deps.get >/dev/null

test: deps
	$(MIX)=test mix compile --warnings-as-errors
	$(MIX)=test mix test

bench: deps
	@if [[ -f $(APP)/bench/structures_bench.exs ]]; then $(MIX)=prod mix run bench/structures_bench.exs; \
	 else echo "ex: no structures bench yet"; fi

harden: deps
	$(MIX)=test mix format --check-formatted
	$(MIX)=test mix xref graph --format cycles --label compile-connected --fail-above 0 >/dev/null
	$(MIX)=test mix test --seed $(SEED)

conform: deps
	$(MIX)=prod mix compile --warnings-as-errors >/dev/null

clean:
	rm -rf $(APP)/_build $(APP)/deps

.PHONY: deps test bench harden conform clean
