# native/rust — thin make façade over cargo so the root Makefile can delegate.
CARGO ?= cargo

all:
	$(CARGO) build --release
test:
	$(CARGO) test --release
bench:
	@echo "rust: benches land in W2c"
harden:
	@echo "rust: miri/fuzz land in W2c"
clean:
	$(CARGO) clean

.PHONY: all test bench harden clean
