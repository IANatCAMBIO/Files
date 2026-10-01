APP      = files
BUNDLE   = $(APP).app
CONTENTS = $(BUNDLE)/Contents
MACOS    = $(CONTENTS)/MacOS
RSRC     = $(CONTENTS)/Resources

CC       = clang

# The version shown in the About panel; edit VERSION to change it.
VERSION  = $(strip $(shell cat VERSION))

# Code-signing identity. macOS ties privacy grants such as Full Disk Access
# to the app's signature: for an ad-hoc ("-") signature that is the exact
# build, so every rebuild loses the grant; for a certificate it is the bundle
# ID plus certificate, which rebuilds keep. Defaults to the first
# "Apple Development" identity in the keychain, else ad hoc. Override with
#   make CODESIGN_IDENTITY="…"   (list: security find-identity -v -p codesigning)
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
# -Werror=unguarded-availability: calling an API newer than the deployment
# target without an @available check is a build error. (Clang cannot check
# messages to __kindof receivers such as NSApp or +sharedApplication.)
# -MMD -MP: emit build/*.d header-dependency files so editing a header
# rebuilds every object that includes it.
CFLAGS   = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
           -Werror=unguarded-availability \
           -mmacosx-version-min=14.0 -I src -MMD -MP
LDFLAGS  = -framework Cocoa -framework CoreServices -framework QuickLookThumbnailing \
           -framework UniformTypeIdentifiers -framework ServiceManagement -framework Quartz
SRCS     = $(wildcard src/*.m)
OBJS     = $(patsubst src/%.m,build/%.o,$(SRCS))
DEPS     = $(OBJS:.o=.d)

.PHONY: all run install clean test

all: $(BUNDLE)

# Info.plist gets the version from VERSION and the time the bundle was
# assembled as FilesBuildDate (UTC), both shown in the About panel.
# Every image in images/ (.png, .icns) is copied into Contents/Resources,
# where the app loads it by name.
IMAGES   = $(wildcard images/*.png images/*.icns)

$(BUNDLE): $(MACOS)/$(APP) resources/Info.plist VERSION $(IMAGES)
	@rm -rf $(RSRC) && mkdir -p $(RSRC)  # fresh, so removed images do not linger
	@cp resources/Info.plist $(CONTENTS)/Info.plist
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(CONTENTS)/Info.plist
	@plutil -replace CFBundleVersion -string "$(VERSION)" $(CONTENTS)/Info.plist
	@plutil -replace FilesBuildDate -string "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" $(CONTENTS)/Info.plist
	@cp $(IMAGES) $(RSRC)/
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(BUNDLE)
	@touch $(BUNDLE)  # codesign rewrites the binary; keep the bundle newer than it

$(MACOS)/$(APP): $(OBJS)
	@mkdir -p $(MACOS)
	$(CC) $(LDFLAGS) -o $@ $^

# Objects also depend on the Makefile so flag changes (e.g. the deployment
# target) rebuild everything.
build/%.o: src/%.m Makefile | build
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
# Install stops if it has not exited after 5 s.
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
	    if pgrep -qxf "$(INSTALLED_BIN)"; then \
	        echo "Files did not quit; quit it (⌘Q) and run make install again" >&2; \
	        exit 1; \
	    fi; \
	    echo "Quit the running Files"; \
	fi; \
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)" && \
	cp -R $(BUNDLE) "$(INSTALL_DIR)/$(BUNDLE)" && \
	echo "Installed to $(INSTALL_DIR)/$(BUNDLE)" && \
	if [ $$running = 1 ]; then open "$(INSTALL_DIR)/$(BUNDLE)" && echo "Reopened Files"; fi

# Engine tests: tests/*_test.m linked against the app's objects (all but
# main.o), run against a scratch folder and a small disk image.
TEST_SRCS = $(wildcard tests/*_test.m)
TEST_BINS = $(patsubst tests/%.m,build/%,$(TEST_SRCS))
APP_OBJS  = $(filter-out build/main.o,$(OBJS))

build/%_test: tests/%_test.m $(APP_OBJS) Makefile | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(APP_OBJS)

test: $(TEST_BINS)
	@for t in $(TEST_BINS); do echo "== $$t"; ./$$t || exit 1; done

clean:
	@rm -rf build $(BUNDLE)
