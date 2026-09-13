# vyto-proxy
#
# VYTO_ROOT is the voltlang checkout holding vytoc and lib/vyto.
# MODPATH is the package root this repo sits in — a root CONTAINS packages, so
# it is the parent directory, not this one.

VYTO_ROOT ?= /home/eric/voltlang
VYTOC     ?= $(VYTO_ROOT)/vytoc
MODPATH   ?= $(realpath ..)
PREFIX    ?= $(HOME)/.local

BINS = domain-to-port vyto-proxyd

all: $(BINS)

domain-to-port: src/cli_main.vt src/routes.vt src/paths.vt src/signal.vt
	$(VYTOC) build src/cli_main.vt --modpath $(MODPATH) -o $@

vyto-proxyd: src/proxyd.vt src/tunnel.vt src/head.vt src/errors.vt src/routes.vt src/paths.vt src/signal.vt src/native/src/hup_shim.c
	$(VYTOC) build src/proxyd.vt --modpath $(MODPATH) -o $@

release: clean-cache
	$(VYTOC) build src/cli_main.vt --modpath $(MODPATH) --release -o domain-to-port
	$(VYTOC) build src/proxyd.vt   --modpath $(MODPATH) --release -o vyto-proxyd

test: all
	sh tests/run_tests.sh

# Bind :80 without running as root. One-time, survives rebuilds only if the
# binary is not replaced — rerun after `make release`.
setcap: vyto-proxyd
	sudo setcap cap_net_bind_service=+ep ./vyto-proxyd

install: release
	install -d $(PREFIX)/bin
	install -m 755 domain-to-port $(PREFIX)/bin/
	install -m 755 vyto-proxyd    $(PREFIX)/bin/
	@echo "installed to $(PREFIX)/bin"
	@echo "grant :80 with: sudo setcap cap_net_bind_service=+ep $(PREFIX)/bin/vyto-proxyd"

# Emitted C and objects are cached per entry-file directory, and editing only a
# library .vt does not always invalidate it. Clear it before trusting a build.
clean-cache:
	find . -name .vyto-cache -type d -exec rm -rf {} + 2>/dev/null || true

clean: clean-cache
	rm -f $(BINS)
	rm -rf tests/tmp

.PHONY: all release test setcap install clean clean-cache
