APP      = files
BUNDLE   = $(APP).app
CONTENTS = $(BUNDLE)/Contents
MACOS    = $(CONTENTS)/MacOS
RSRC     = $(CONTENTS)/Resources

CC       = clang
CFLAGS   = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
           -Wno-deprecated-declarations \
           -mmacosx-version-min=13.0 -I src
LDFLAGS  = -framework Cocoa -framework CoreServices -framework QuickLookThumbnailing
SRCS     = $(wildcard src/*.m)
OBJS     = $(patsubst src/%.m,build/%.o,$(SRCS))

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

build/%.o: src/%.m | build
	$(CC) $(CFLAGS) -c -o $@ $<

build:
	@mkdir -p build

run: all
	@open $(BUNDLE)

install: all
	@cp -r $(BUNDLE) /Applications/$(BUNDLE)
	@echo "Installed to /Applications/$(BUNDLE)"

clean:
	@rm -rf build $(BUNDLE)
