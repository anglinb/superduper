# superduper — build, test, install, uninstall.
# Needs only the Xcode Command Line Tools (`xcode-select --install`).

PREFIX   ?= $(HOME)/.local
BIN      := $(PREFIX)/bin/superduper
LABEL    := local.superduper
PLIST    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG      := $(HOME)/Library/Logs/superduper.log
DOMAIN   := gui/$(shell id -u)

CORE     := Sources/Engine.swift Sources/Geometry.swift
SOURCES  := $(CORE) Sources/main.swift
SWIFTC   := swiftc -swift-version 5

.PHONY: all test install uninstall restart status clean

all: build/superduper

build/superduper: $(SOURCES)
	@mkdir -p build
	$(SWIFTC) -O -o $@ $(SOURCES)
	codesign --force --sign - --identifier $(LABEL) --options runtime $@

build/tests: $(CORE) Tests/main.swift
	@mkdir -p build
	$(SWIFTC) -o $@ $(CORE) Tests/main.swift

test: build/tests
	build/tests

install: test build/superduper
	install -d $(dir $(BIN)) $(dir $(PLIST))
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	install -m 755 build/superduper $(BIN)
	sed -e 's|__BIN__|$(BIN)|' -e 's|__LOG__|$(LOG)|' $(LABEL).plist > $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo
	@echo "Installed. Now allow it: System Settings → Privacy & Security → Accessibility → superduper."
	@echo "(After a rebuild, remove the old entry with − and allow the new one.)"

uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(BIN) $(PLIST)
	@echo "Uninstalled. Also remove superduper from System Settings → Privacy & Security → Accessibility."

restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

status:
	@launchctl print $(DOMAIN)/$(LABEL) 2>/dev/null | grep -E '^\s+(state|pid|last exit code) =' || echo "not loaded"
	@tail -n 5 $(LOG) 2>/dev/null || true

clean:
	rm -rf build
