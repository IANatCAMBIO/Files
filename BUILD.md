# Build

## Toolchain

- **Compiler**: `clang` (Apple LLVM, included with Xcode Command Line Tools)
- **Minimum macOS**: 14.0 (Sonoma)
- **Language**: Objective-C with ARC (`-fobjc-arc`)

Install the toolchain if missing:

```sh
xcode-select --install
```

## Dependencies

No third-party libraries. All dependencies are Apple system frameworks:

| Framework       | Purpose                                      |
|-----------------|----------------------------------------------|
| Cocoa           | AppKit (UI), Foundation (collections, URLs)  |
| CoreServices    | FSEventStream for directory watching         |

## Build targets

| Target          | Command         | Description                            |
|-----------------|-----------------|----------------------------------------|
| Build (default) | `make`          | Compiles and assembles `files.app`     |
| Run             | `make run`      | Builds then opens the app with `open`  |
| Install         | `make install`  | Replaces `~/Applications/files.app` with the new build |
| Clean           | `make clean`    | Removes `build/` and `files.app`       |

## Output

The build produces `files.app/` in the project root:

```
files.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── files          ← compiled binary
    └── Resources/
```

## Incremental builds and compiler checks

- Header dependencies are tracked automatically (`-MMD -MP` writes `build/*.d`),
  so editing a header rebuilds every `.m` that includes it. Editing the
  `Makefile` rebuilds everything. A plain `make` is always enough; `make clean`
  is never required for correctness.
- `-Werror=unguarded-availability` makes it a build error to call an API newer
  than the deployment target (macOS 14.0) without an `@available` check.
  Clang cannot check messages sent to `__kindof` receivers (for example
  `NSApp` or `+[NSApplication sharedApplication]`), so review those by hand.

## Source layout

```
src/
├── main.m               — entry point
├── app_delegate.h/.m    — app lifecycle, menu bar
├── main_window.h/.m     — NSSplitView + toolbar
├── browser_view.h/.m    — file list (NSTableView + FSEvents)
├── sidebar.h/.m         — places/devices NSOutlineView
├── file_ops.h/.m        — clipboard, trash, rename, new folder
├── info_panel.h/.m      — Get Info panel
└── volume_manager.h/.m  — volume enumeration and eject
```

## Platform notes

- Requires macOS 14 (Sonoma) or later; the deployment target (`-mmacosx-version-min`) and `LSMinimumSystemVersion` are both 14.0. macOS 13 is not supported.
- The app is not sandboxed; it accesses arbitrary paths with full user permissions.
- `NSWorkspace.recycleURLs:completionHandler:` is used for trash (not `NSFileManager.trashItemAtURL:`), so Finder's trash animation plays.
