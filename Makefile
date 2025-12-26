# MquickjsEx NIF Makefile
#
# Two-stage build:
# 1. Build stdlib generator (host tool)
# 2. Generate mquickjs_ex_stdlib.h and mquickjs_atom.h
# 3. Build NIF shared library

# Erlang paths
ERL_INCLUDE_PATH ?= $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)

# Compiler settings
HOST_CC = cc
CC = cc
CFLAGS = -O2 -Wall -fPIC -D_GNU_SOURCE -fno-math-errno -fno-trapping-math
HOST_CFLAGS = -O2 -Wall -D_GNU_SOURCE -fno-math-errno -fno-trapping-math

# Platform-specific settings
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LDFLAGS = -dynamiclib -undefined dynamic_lookup
    SO_EXT = .so
else
    LDFLAGS = -shared
    SO_EXT = .so
endif

# Directories
C_SRC_DIR = c_src
VENDOR_DIR = $(C_SRC_DIR)/vendor
PRIV_DIR = priv

# Source files
VENDOR_SOURCES = $(VENDOR_DIR)/mquickjs.c $(VENDOR_DIR)/dtoa.c $(VENDOR_DIR)/libm.c $(VENDOR_DIR)/cutils.c
NIF_SOURCE = $(C_SRC_DIR)/mquickjs_ex.c

# Output files
NIF_SO = $(PRIV_DIR)/mquickjs_ex$(SO_EXT)
STDLIB_GEN = $(C_SRC_DIR)/mquickjs_ex_stdlib_gen
STDLIB_HEADER = $(C_SRC_DIR)/mquickjs_ex_stdlib.h
ATOM_HEADER = $(C_SRC_DIR)/mquickjs_atom.h

# Default target
all: $(NIF_SO)

# Stage 1: Build the stdlib generator (host tool)
$(STDLIB_GEN): $(C_SRC_DIR)/mquickjs_ex_stdlib.c $(VENDOR_DIR)/mquickjs_build.c
	$(HOST_CC) $(HOST_CFLAGS) -o $@ $^ -I$(VENDOR_DIR)

# Stage 2: Generate headers
$(ATOM_HEADER): $(STDLIB_GEN)
	cd $(C_SRC_DIR) && ./mquickjs_ex_stdlib_gen -a > mquickjs_atom.h

$(STDLIB_HEADER): $(STDLIB_GEN)
	cd $(C_SRC_DIR) && ./mquickjs_ex_stdlib_gen > mquickjs_ex_stdlib.h

# Stage 3: Build NIF
$(NIF_SO): $(NIF_SOURCE) $(VENDOR_SOURCES) $(STDLIB_HEADER) $(ATOM_HEADER) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(NIF_SOURCE) $(VENDOR_SOURCES) \
		-I$(VENDOR_DIR) -I$(C_SRC_DIR) -I$(ERL_INCLUDE_PATH) -lm

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

# Clean
clean:
	rm -f $(NIF_SO) $(STDLIB_GEN) $(STDLIB_HEADER) $(ATOM_HEADER)
	rm -f $(C_SRC_DIR)/*.o $(VENDOR_DIR)/*.o

.PHONY: all clean
