PREFIX ?= /usr/local
DESTDIR ?=

BINDIR = $(DESTDIR)$(PREFIX)/bin
LIBDIR = $(DESTDIR)$(PREFIX)/lib/slopology
MANDIR = $(DESTDIR)$(PREFIX)/share/man/man1

.PHONY: all test install uninstall

all:
	@printf '%s\n' "Nothing to build. Try: ./bin/slopology --help" "or: make install"

test:
	sh tests/run.sh

install:
	install -d "$(BINDIR)" "$(LIBDIR)" "$(MANDIR)"
	install -m 755 bin/slopology "$(BINDIR)/slopology"
	install -m 644 lib/sky.sh lib/sky.awk "$(LIBDIR)/"
	install -m 644 man/slopology.1 "$(MANDIR)/slopology.1"

uninstall:
	rm -f "$(BINDIR)/slopology" "$(MANDIR)/slopology.1"
	rm -f "$(LIBDIR)/sky.sh" "$(LIBDIR)/sky.awk"
	-rmdir "$(LIBDIR)" 2>/dev/null || true
