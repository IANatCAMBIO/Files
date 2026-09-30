# Build

## Toolchain

- **Compiler**: `clang` (Apple LLVM, included with Xcode Command Line Tools)
- **Minimum macOS**: 13.0 (Ventura)
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
| Install         | `make install`  | Copies `files.app` to `/Applications` |
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

- Tested on macOS 13 (Ventura) and 14 (Sonoma).
- The app is not sandboxed; it accesses arbitrary paths with full user permissions.
- `NSWorkspace.recycleURLs:completionHandler:` is used for trash (not `NSFileManager.trashItemAtURL:`), so Finder's trash animation plays.
