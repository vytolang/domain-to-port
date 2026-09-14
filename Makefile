# vyto-proxy
#
# Building needs the Vyto compiler. Point at it however suits you:
#
#     make                          # vytoc on PATH, or $VYTO_HOME/vytoc
#     make VYTOC=/path/to/vytoc     # an explicit binary
#     make VYTO_ROOT=~/vyto         # a voltlang checkout holding ./vytoc
#
# MODPATH is the package root this repo sits in. A root CONTAINS packages, so
# it is the parent directory, not this one — the same shape as lib/ holding
# vyto/. Derived from this file's location, so moving the checkout needs no
# edit.

MODPATH   ?= $(realpath ..)
PREFIX    ?= $(HOME)/.local
DESTDIR   ?=

# Find the compiler: an explicit VYTOC wins, then a VYTO_ROOT checkout, then
# $VYTO_HOME, then PATH. Left empty when nothing is found, which `check-vytoc`
# turns into an error naming the ways to fix it.
ifdef VYTO_ROOT
VYTOC     ?= $(VYTO_ROOT)/vytoc
else ifdef VYTO_HOME
VYTOC     ?= $(VYTO_HOME)/vytoc
else
VYTOC     ?= $(shell command -v vytoc 2>/dev/null)
endif

BINS = domain-to-port vyto-proxyd

CLI_SRC = src/cli_main.vt src/routes.vt src/paths.vt src/signal.vt src/hosts.vt
DAEMON_SRC = src/proxyd.vt src/tunnel.vt src/head.vt src/errors.vt src/routes.vt \
             src/paths.vt src/signal.vt src/tls.vt src/sni.vt src/acme.vt \
             src/jws.vt src/challenge.vt src/certstore.vt src/autocert.vt \
             src/native/src/hup_shim.c src/native/src/selfsign_shim.c \
             src/native/src/sni_shim.c src/native/src/acme_shim.c

all: $(BINS)

# Every build target depends on this, so a missing compiler is one clear
# message rather than "vytoc: command not found" repeated per file.
check-vytoc:
	@if [ -z "$(VYTOC)" ] || [ ! -x "$(VYTOC)" ]; then \
		echo "vyto-proxy: cannot find the Vyto compiler."; \
		echo ""; \
		echo "  Install Vyto from https://github.com/vytolang/vyto, then either:"; \
		echo "    - put vytoc on your PATH"; \
		echo "    - set VYTO_HOME to the install root"; \
		echo "    - build here with: make VYTO_ROOT=/path/to/vyto-checkout"; \
		echo "    - or point straight at it: make VYTOC=/path/to/vytoc"; \
		echo ""; \
		echo "  Prebuilt binaries need no compiler:"; \
		echo "    https://github.com/vytolang/domain-to-port/releases"; \
		exit 1; \
	fi

domain-to-port: $(CLI_SRC) | check-vytoc
	$(VYTOC) build src/cli_main.vt --modpath $(MODPATH) -o $@

vyto-proxyd: $(DAEMON_SRC) | check-vytoc
	$(VYTOC) build src/proxyd.vt --modpath $(MODPATH) -o $@

# What a release is built with: optimised, and from a cleared cache so nothing
# stale can survive into a published artifact.
release: check-vytoc clean-cache
	$(VYTOC) build src/cli_main.vt --modpath $(MODPATH) --release -o domain-to-port
	$(VYTOC) build src/proxyd.vt   --modpath $(MODPATH) --release -o vyto-proxyd

test: all
	sh tests/run_tests.sh

# Bind :80 without running as root. Attached to the file, so it must be redone
# after any rebuild that replaces the binary.
setcap: vyto-proxyd
	sudo setcap cap_net_bind_service=+ep ./vyto-proxyd

install: release
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 domain-to-port $(DESTDIR)$(PREFIX)/bin/
	install -m 755 vyto-proxyd    $(DESTDIR)$(PREFIX)/bin/
	@echo "installed to $(DESTDIR)$(PREFIX)/bin"
	@echo "grant :80 with: sudo setcap cap_net_bind_service=+ep $(PREFIX)/bin/vyto-proxyd"

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/domain-to-port $(DESTDIR)$(PREFIX)/bin/vyto-proxyd

# A release tarball plus checksums, for attaching to a GitHub release. The
# platform tag is the machine's own, since these binaries are not cross-built.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLATFORM ?= $(shell uname -s | tr A-Z a-z)-$(shell uname -m)
DISTNAME = domain-to-port-$(VERSION)-$(PLATFORM)

dist: release
	rm -rf dist/$(DISTNAME)
	mkdir -p dist/$(DISTNAME)
	cp domain-to-port vyto-proxyd README.md LICENSE dist/$(DISTNAME)/ 2>/dev/null || \
		cp domain-to-port vyto-proxyd README.md dist/$(DISTNAME)/
	cp contrib/vyto-proxyd.service dist/$(DISTNAME)/
	cd dist && tar czf $(DISTNAME).tar.gz $(DISTNAME)
	cd dist && sha256sum $(DISTNAME).tar.gz > $(DISTNAME).tar.gz.sha256
	# A copy under a stable name, so /releases/latest/download/<file> resolves
	# without knowing the version. Both are attached to the release.
	cd dist && cp $(DISTNAME).tar.gz domain-to-port-$(PLATFORM).tar.gz
	cd dist && sha256sum domain-to-port-$(PLATFORM).tar.gz > domain-to-port-$(PLATFORM).tar.gz.sha256
	@echo "dist/$(DISTNAME).tar.gz"
	@echo "dist/domain-to-port-$(PLATFORM).tar.gz"

# Emitted C and objects are cached per entry-file directory, and editing only a
# library .vt does not always invalidate it. Clear it before trusting a build.
clean-cache:
	find . -name .vyto-cache -type d -exec rm -rf {} + 2>/dev/null || true

clean: clean-cache
	rm -f $(BINS)
	rm -rf tests/tmp dist

.PHONY: all check-vytoc release test setcap install uninstall dist clean clean-cache
