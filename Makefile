APP      = files
BUNDLE   = $(APP).app
CONTENTS = $(BUNDLE)/Contents
MACOS    = $(CONTENTS)/MacOS
RSRC     = $(CONTENTS)/Resources

CC       = clang
# -Werror=unguarded-availability: calling an API newer than the deployment
# target without an @available check is a build error. (Clang cannot check
# messages to __kindof receivers such as NSApp or +sharedApplication.)
# -MMD -MP: emit build/*.d header-dependency files so editing a header
# rebuilds every object that includes it.
CFLAGS   = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
           -Wno-deprecated-declarations -Werror=unguarded-availability \
           -mmacosx-version-min=14.0 -I src -MMD -MP
LDFLAGS  = -framework Cocoa -framework CoreServices -framework QuickLookThumbnailing
SRCS     = $(wildcard src/*.m)
OBJS     = $(patsubst src/%.m,build/%.o,$(SRCS))
DEPS     = $(OBJS:.o=.d)

.PHONY: all run install clean

all: $(BUNDLE)

$(BUNDLE): $(MACOS)/$(APP) resources/Info.plist folder.png documents.png
	@mkdir -p $(RSRC)
	@cp resources/Info.plist $(CONTENTS)/Info.plist
	@cp folder.png    $(RSRC)/folder.png
	@cp documents.png $(RSRC)/documents.png
	@codesign --force --sign - $(BUNDLE)

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
INSTALL_DIR = $(HOME)/Applications

install: all
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	@cp -R $(BUNDLE) "$(INSTALL_DIR)/$(BUNDLE)"
	@echo "Installed to $(INSTALL_DIR)/$(BUNDLE)"

clean:
	@rm -rf build $(BUNDLE)
