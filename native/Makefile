# native/ — delegates to the per-language trees. Targets every tree implements:
#   all  test  bench  harden  clean
SUBDIRS := c rust

all test bench harden clean:
	@for d in $(SUBDIRS); do $(MAKE) -C $$d $@ || exit 1; done

.PHONY: all test bench harden clean
