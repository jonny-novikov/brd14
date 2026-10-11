# scripts/ — the shell tools (brd.sh, mint.sh) and the environment scripts.
# The codec in brd.sh is proven by tools/parity.py (shim sh-bash); this target
# covers what parity cannot see: minting, settings, the census, the CLI surface.
test:
	bash test_brd.sh
bench:
	@echo "scripts: no bench (the shell CLI is for hands-on use, not throughput)"
harden:
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -S warning brd.sh mint.sh test_brd.sh setup.sh; \
	 else echo "scripts: shellcheck not installed; skipping lint"; fi
	bash -n brd.sh && bash -n mint.sh && bash -n test_brd.sh
clean:
	@true

.PHONY: test bench harden clean
