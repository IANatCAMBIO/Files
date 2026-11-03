APP      = Files
BUNDLE   = $(APP).app
CONTENTS = $(BUNDLE)/Contents
MACOS    = $(CONTENTS)/MacOS
RSRC     = $(CONTENTS)/Resources

CC       = clang

# The interface Files shares with Notes and Tasks (the tool panel, notices
# and confirmations, colours, ...) lives in the shared_ui repository beside
# this one and is compiled in from source.
SHARED_UI_DIR ?= $(CURDIR)/../shared_ui
# Modules for parts of the interface Files does not have are left out, along
# with the frameworks they would pull in: shared_hotkey (Quick Task's
# system-wide shortcut) needs Carbon, and the day planner and the Calendar
# it reads need EventKit.
SHARED_UI_SRCS = $(filter-out %/shared_hotkey.m %/shared_day_planner.m %/shared_calendar.m,\
                   $(wildcard $(SHARED_UI_DIR)/src/*.m))
ifeq ($(SHARED_UI_SRCS),)
$(error $(SHARED_UI_DIR)/src has no sources: check out shared_ui beside this repository or set SHARED_UI_DIR)
endif

# The version shown in the About panel; edit VERSION to change it.
VERSION := $(strip $(shell cat VERSION))

# Code-signing identity. macOS ties privacy grants such as Full Disk Access
# to the app's signature: for an ad-hoc ("-") signature that is the exact
# build, so every rebuild loses the grant; for a certificate it is the bundle
# ID plus certificate, which rebuilds keep. Defaults to the first
# "Apple Development" identity in the keychain, else ad hoc. Override with
#   make CODESIGN_IDENTITY="…"   (list: security find-identity -v -p codesigning)
#
# Only goals that build the bundle look the identity up: `make clean` and
# the test targets other than test-build do not sign anything, so they skip the keychain query.
SIGNING_GOALS := $(if $(MAKECMDGOALS),$(filter-out clean test test-unit test-features test-ui,$(MAKECMDGOALS)),all)
ifneq ($(SIGNING_GOALS),)
ifeq ($(origin CODESIGN_IDENTITY),undefined)
CODESIGN_IDENTITY := $(or $(shell security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1),-)
endif

# build/codesign.id records the signing identity. When the identity changes
# it is rewritten (while the Makefile is read) and the bundle is backdated,
# which forces a re-sign even within the same second as the last build; an
# unchanged identity triggers nothing.
$(shell mkdir -p build && (echo '$(CODESIGN_IDENTITY)' | cmp -s - build/codesign.id \
    || { echo '$(CODESIGN_IDENTITY)' > build/codesign.id; \
         [ -d $(BUNDLE) ] && touch -t 200001010000 $(BUNDLE); true; }))
endif
# -Werror=unguarded-availability: calling an API newer than the deployment
# target without an @available check is a build error. (Clang cannot check
# messages to __kindof receivers such as NSApp or +sharedApplication.)
# -MMD -MP: emit build/*.d header-dependency files so editing a header
# rebuilds every object that includes it.
# -Wno-unused-parameter: the parameters left unused are ones callback
# signatures require (blocks, FSEvents and notification handlers), which
# would otherwise each need a (void) cast.
CFLAGS   = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
           -Werror=unguarded-availability \
           -mmacosx-version-min=14.0 -I src -I $(SHARED_UI_DIR)/src -MMD -MP
LDFLAGS  = -framework Cocoa -framework CoreServices -framework QuickLookThumbnailing \
           -framework UniformTypeIdentifiers -framework ServiceManagement -framework Quartz
SRCS     = $(wildcard src/*.m)
OBJS     = $(patsubst src/%.m,build/%.o,$(SRCS)) \
           $(patsubst $(SHARED_UI_DIR)/src/%.m,build/%.o,$(SHARED_UI_SRCS))
DEPS     = $(OBJS:.o=.d)

.PHONY: all run install clean test test-build test-unit test-features test-ui

all: $(BUNDLE)

# Info.plist gets the executable's name from APP, the version from VERSION
# and the time the bundle was assembled as FilesBuildDate (UTC), both shown
# in the About panel.
#
# The images the app loads by name, copied into Contents/Resources. Named
# one by one rather than taken with a wildcard over images/, which also
# holds the README's screenshot: that put 741 KB of documentation, and a
# leftover nothing loads, inside every bundle. Adding an image here is what
# it takes to bundle it.
IMAGES   = images/documents.png images/git96.png

# The app icon (Info.plist CFBundleIconFile, and files_app_icon() in the
# app) is built from resources/app_icon.png, a 1024x1024 PNG with a
# transparent background: sips renders it at every size an iconset holds
# and iconutil packs those into one .icns. Both tools ship with macOS.
ICON_SRC = resources/app_icon.png
ICON     = build/app_icon.icns
ICONSET  = build/app_icon.iconset

# sips now and then cannot rename its temporary file into the iconset
# directory ("Error 13: an unknown error occurred"), which left the iconset
# short of a size or two; iconutil then either failed or packed an icns
# missing them, and the error surfaced further on as a bundle that would
# not assemble. Each render is retried and its output checked, and a size
# that still will not render stops the build where it went wrong.
$(ICON): $(ICON_SRC) | build
	@rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	@render() { \
	    for try in 1 2 3; do \
	        sips -z $$1 $$1 $< --out "$$2" >/dev/null 2>&1 && [ -s "$$2" ] && return 0; \
	        sleep 1; \
	    done; \
	    echo "$@: could not render $$2 at $$1 px" >&2; \
	    return 1; \
	}; \
	for s in 16 32 128 256 512; do \
	    render $$s $(ICONSET)/icon_$${s}x$${s}.png || exit 1; \
	    render $$((s * 2)) $(ICONSET)/icon_$${s}x$${s}@2x.png || exit 1; \
	done
	@iconutil -c icns -o $@ $(ICONSET)

$(BUNDLE): $(MACOS)/$(APP) resources/Info.plist VERSION $(IMAGES) $(ICON)
	@rm -rf $(RSRC) && mkdir -p $(RSRC)  # fresh, so removed images do not linger
	@cp resources/Info.plist $(CONTENTS)/Info.plist
	@plutil -replace CFBundleExecutable -string "$(APP)" $(CONTENTS)/Info.plist
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(CONTENTS)/Info.plist
	@plutil -replace CFBundleVersion -string "$(VERSION)" $(CONTENTS)/Info.plist
	@plutil -replace FilesBuildDate -string "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" $(CONTENTS)/Info.plist
	@cp -X $(IMAGES) $(ICON) $(RSRC)/
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(BUNDLE)
	@touch $(BUNDLE)  # codesign rewrites the binary; keep the bundle newer than it

$(MACOS)/$(APP): $(OBJS)
	@mkdir -p $(MACOS)
	$(CC) $(LDFLAGS) -o $@ $^

# Objects also depend on the Makefile so flag changes (e.g. the deployment
# target) rebuild everything.
build/%.o: src/%.m Makefile | build
	$(CC) $(CFLAGS) -c -o $@ $<

build/%.o: $(SHARED_UI_DIR)/src/%.m Makefile | build
	$(CC) $(CFLAGS) -c -o $@ $<

-include $(DEPS)

build:
	@mkdir -p build


run: all
	@open $(BUNDLE)

# Per-user install: no sudo needed. The old bundle is removed first because
# `cp -r` into an existing bundle directory would nest the new one inside it.
#
# If the installed Files is running — with Keep Files running it stays up
# with no windows open — it is stopped first (SIGTERM; Files has nothing to
# save on quit) and reopened afterwards, so the new build is what runs.
# It is killed (SIGKILL) if it has not exited after 5 s.
INSTALL_DIR   = $(HOME)/Applications
INSTALLED_BIN = $(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP)

install: all
	@mkdir -p "$(INSTALL_DIR)"
	@running=0; \
	if pgrep -qxf "$(INSTALLED_BIN)"; then \
	    running=1; \
	    pkill -TERM -xf "$(INSTALLED_BIN)"; \
	    for i in 1 2 3 4 5 6 7 8 9 10; do \
	        pgrep -qxf "$(INSTALLED_BIN)" || break; sleep 0.5; \
	    done; \
	    pkill -KILL -xf "$(INSTALLED_BIN)" 2>/dev/null; \
	    echo "Stopped the running Files"; \
	fi; \
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)" && \
	cp -R $(BUNDLE) "$(INSTALL_DIR)/$(BUNDLE)" && \
	echo "Installed to $(INSTALL_DIR)/$(BUNDLE)" && \
	if [ $$running = 1 ]; then \
	    for try in 1 2 3; do \
	        open "$(INSTALL_DIR)/$(BUNDLE)" >/dev/null 2>&1; \
	        for i in 1 2 3 4 5 6; do \
	            pgrep -qxf "$(INSTALLED_BIN)" && break 2; sleep 0.5; \
	        done; \
	    done; \
	    if pgrep -qxf "$(INSTALLED_BIN)"; then echo "Reopened Files"; \
	    else echo "Files is installed but did not reopen; open it yourself"; fi; \
	fi

# Engine tests: tests/*_test.m linked against the app's objects (all but
# main.o), run against a scratch folder and a small disk image.
TEST_SRCS = $(wildcard tests/*_test.m)
TEST_BINS = $(patsubst tests/%.m,build/%,$(TEST_SRCS))
APP_OBJS  = $(filter-out build/main.o,$(OBJS))

build/%_test: tests/%_test.m $(APP_OBJS) Makefile | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(APP_OBJS)

test-unit: $(TEST_BINS)
	@for t in $(TEST_BINS); do echo "== $$t"; ./$$t || exit 1; done
	@echo "test-unit: ok"

# ── Release checks ───────────────────────────────────────────────────────
# Not dependencies of all/run/install: they run only when asked for (a
# release). `make test` runs all four; each is also a target of its own.
test: test-build test-unit test-features test-ui
	@echo "all release checks passed"

# test-build: a from-scratch build has zero warnings, and the bundle is
# sound (valid Info.plist, executable present, signature verifies).
BUILD_LOG = build/build.log

test-build:
	@$(MAKE) clean
	@mkdir -p build
	@$(MAKE) all > $(BUILD_LOG) 2>&1 || { cat $(BUILD_LOG); exit 1; }
	@! grep -q 'warning:' $(BUILD_LOG) || { grep 'warning:' $(BUILD_LOG); echo "test-build: warnings"; exit 1; }
	@plutil -lint $(CONTENTS)/Info.plist >/dev/null
	@test -x $(MACOS)/$(APP)
	@codesign --verify --strict $(BUNDLE)
	@echo "test-build: ok"

# test-features: each user-visible feature driven through the app's own
# code on seeded scratch data (tests/features/). None written yet.
test-features:
	@echo "test-features: no feature tests yet (tests/features/)"

# test-ui: tests/ui/ui_check.m linked against every app object but main.o.
# It builds the real windows in this process, checks the chrome (titled
# window, expanded toolbar, no header bar), renders light and dark PNG
# snapshots to build/snapshots, and checks that a closed browser window is
# released. In-process, so it needs no Screen Recording or Accessibility
# grant. It runs from a throwaway bundle under build/ so the app icon is
# found the way the app finds it.
UI_CHECK_APP  = build/ui_check.app/Contents
UI_CHECK_BIN  = $(UI_CHECK_APP)/MacOS/ui_check
SNAPSHOT_DIR  = build/snapshots

$(UI_CHECK_BIN): tests/ui/ui_check.m $(APP_OBJS) $(ICON) Makefile | build
	@rm -rf build/ui_check.app && mkdir -p $(UI_CHECK_APP)/MacOS $(UI_CHECK_APP)/Resources
	@cp $(ICON) $(IMAGES) $(UI_CHECK_APP)/Resources/
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(APP_OBJS)

test-ui: $(UI_CHECK_BIN)
	@rm -rf $(SNAPSHOT_DIR)
	./$(UI_CHECK_BIN) "$(CURDIR)/$(SNAPSHOT_DIR)"
	@echo "test-ui: ok"

clean:
	@rm -rf build $(BUNDLE)
