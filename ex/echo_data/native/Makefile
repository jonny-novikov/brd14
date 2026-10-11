# Builds the optional native codec into ../priv. The application runs without
# it (pure Elixir fallback); with it, decode/encode/hash run in the Rust core.
ERTS_INCLUDE ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include",[code:root_dir(),erlang:system_info(version)])' -s init stop)
PRIV := ../priv

all: $(PRIV)/echo_native.so

$(PRIV)/libbranded_rs.so: branded_id.rs
	mkdir -p $(PRIV)
	rustc --crate-type cdylib -C opt-level=3 -C panic=abort -o $@ branded_id.rs

$(PRIV)/echo_native.so: echo_native.c $(PRIV)/libbranded_rs.so branded_id.h
	gcc -O2 -Wall -fPIC -shared -I"$(ERTS_INCLUDE)" -o $@ echo_native.c \
	    -L$(PRIV) -lbranded_rs -Wl,-rpath,'$$ORIGIN'

# Reference build against the C core instead of Rust:
c-core: echo_native.c branded_id.c branded_id.h
	mkdir -p $(PRIV)
	gcc -O2 -Wall -fPIC -shared -I"$(ERTS_INCLUDE)" -o $(PRIV)/echo_native.so echo_native.c branded_id.c

clean:
	rm -f $(PRIV)/echo_native.so $(PRIV)/libbranded_rs.so

.PHONY: all c-core clean
