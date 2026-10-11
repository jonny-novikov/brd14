# native/c — the C cores. Variants live in sibling folders and share one ABI
# header (../include/branded_id.h); every target here builds each variant.
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Werror -std=c11 -fPIC
INC     := -I../include
BUILD   := build
VARIANTS := speed

all: $(VARIANTS:%=$(BUILD)/%/branded_id.o)

$(BUILD)/%/branded_id.o: %/branded_id.c ../include/branded_id.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(INC) -c $< -o $@

test: all
	@echo "c: vector/property tests land in W2b"
bench harden:
	@echo "c: $@ lands in W2b"

clean:
	rm -rf $(BUILD)

.PHONY: all test bench harden clean
