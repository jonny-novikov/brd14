# ex/: the Elixir home — echo_data, standalone (Elixir >= 1.14, OTP >= 25).
#
#   make test           compile --warnings-as-errors with the NIF required, the suite with the NIF,
#                       then the suite again on the pure path (ECHO_DATA_NATIVE=0)
#   make bench          the structures bench -> ../bench/results/structures/
#   make harden         format check, no compile-time cycles (xref), the suite under a fixed seed
#   make conform        build what the parity shims run (ex-pure, ex-nif)
#   make package        the Hex tarball, crates vendored -> ../build/ex/echo_data.tar
#   make package-check  unpack it outside the repository; build it there with the NIF required
#                       and smoke-test codec, champ and fallback
#   make clean          _build, deps, the NIF build, staging
SHELL   := /bin/bash
APP     := echo_data
MIX     := cd $(APP) && TMPDIR=/tmp MIX_ENV
SEED    ?= 0
BUILD   := ../build/ex
CHECK   := /tmp/echo_data-package-check
# Inside this repository the NIF is part of the proof: a failed build is an error, not a fallback
# — once its Rust crates exist (brd14-data lands with R4); until then the NIF is skipped.
export ECHO_DATA_NIF ?= $(if $(wildcard ../native/rust/crates/brd14-data/Cargo.toml),1,0)

deps:
	cd $(APP) && TMPDIR=/tmp mix deps.get >/dev/null

test: deps
	$(MIX)=test mix compile --warnings-as-errors
	$(MIX)=test mix test
	$(MIX)=test ECHO_DATA_NATIVE=0 mix test

bench: deps
	@if [[ -f $(APP)/bench/structures_bench.exs ]]; then $(MIX)=prod mix run bench/structures_bench.exs; \
	 else echo "ex: no structures bench yet"; fi

harden: deps
	$(MIX)=test mix format --check-formatted
	$(MIX)=test mix xref graph --format cycles --label compile-connected --fail-above 0 >/dev/null
	$(MIX)=test mix test --seed $(SEED)

conform: deps
	$(MIX)=prod mix compile --warnings-as-errors >/dev/null

package: deps
	python3 package.py $(BUILD)/stage
	cd $(BUILD)/stage && TMPDIR=/tmp MIX_ENV=prod mix hex.build -o ../echo_data.tar

# The falsifying check for "redistributable": the unpacked tarball must build alone, with the
# repository's crates out of reach (unpacked outside the tree, so no ../../.. path resolves).
package-check: package
	rm -rf $(CHECK) && mkdir -p $(CHECK)
	tar -xOf $(BUILD)/echo_data.tar contents.tar.gz | tar -xzf - -C $(CHECK)
	cd $(CHECK) && TMPDIR=/tmp mix deps.get >/dev/null
	cd $(CHECK) && TMPDIR=/tmp MIX_ENV=prod ECHO_DATA_NIF=1 mix compile >/dev/null
	cd $(CHECK) && TMPDIR=/tmp MIX_ENV=prod mix run -e '\
	  true = EchoData.Native.loaded?(); \
	  {:ok, :native} = EchoData.BrandedId.self_check!(); \
	  c = EchoData.NativeChamp.new([{"USR0KHTOWnGLuC", :v}]); \
	  {:ok, :v} = EchoData.NativeChamp.fetch(c, "USR0KHTOWnGLuC"); \
	  IO.puts("package-check: NIF loaded, self-check native, NativeChamp round trip ok")'
	cd $(CHECK) && TMPDIR=/tmp MIX_ENV=prod ECHO_DATA_NATIVE=0 mix run -e '\
	  {:ok, :pure} = EchoData.BrandedId.self_check!(); IO.puts("package-check: pure fallback ok")'

clean:
	rm -rf $(APP)/_build $(APP)/deps $(APP)/native/echo_data_nif/target $(APP)/priv/*.so $(BUILD)

.PHONY: deps test bench harden conform package package-check clean
