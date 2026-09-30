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
| CoreServices    | FSEventStream for folder watching            |
| QuickLookThumbnailing | Thumbnails in the info sidebar         |
| UniformTypeIdentifiers | Per-file-type icon lookup (icon cache) |

The C library's `copyfile(3)`, `renamex_np(2)` and CommonCrypto (SHA-256 / MD5)
are part of libSystem and need no extra linking.

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
├── main.m                  — entry point
├── app_delegate.h/.m       — app lifecycle, menu bar, Devices menu
├── main_window.h/.m        — window controller: toolbar, split views, pane
│                             switching, Go-menu and view-preference actions
├── browser_pane.h/.m       — one pane: browser view + per-pane state
├── browser_view.h/.m       — file list (NSTableView), background listing,
│                             FSEvents watcher, Spotlight search, history
├── bookmarks_bar.h/.m      — bookmarks strip above the browser
├── info_sidebar.h/.m       — collapsible Quick Look / details sidebar
├── info_panel.h/.m         — Get Info panel (permissions, lock, hashes)
├── file_ops.h/.m           — pasteboard, copy/move engine (copyfile +
│                             rename, staged commits), trash, rename, mkdir
├── copy_progress.h/.m      — copy progress panel and conflict prompts
├── speed_graph.h/.m        — bounded transfer-speed graph
├── file_hash.h/.m          — single-pass, cancellable SHA-256 / MD5
├── mounts_panel.h/.m       — All Mounts panel (per-volume unmount)
├── volume_manager.h/.m     — mounted-volume list and unmount
├── default_viewer.h/.m     — takes over from Finder as default file viewer
│                             (NSFileViewer, Finder settings) and restores
│                             the recorded originals
└── util.h/.m               — shared helpers: preference keys, other apps'
                              preferences (`defaults`), standard folder
                              URLs, size/date formatting, error alerts
```

## Code signing

The bundle is signed with `CODESIGN_IDENTITY`, which defaults to the first
"Apple Development" identity in your keychain, or `-` (ad hoc) if there is
none. Privacy grants such as Full Disk Access follow the signature: with a
certificate they survive rebuilds; with an ad-hoc signature they are tied to
one build. `build/codesign.id` records the identity so that changing it
re-signs the bundle on the next `make`. See README ▸ Full Disk Access.

## Platform notes

- Requires macOS 14 (Sonoma) or later; the deployment target (`-mmacosx-version-min`) and `LSMinimumSystemVersion` are both 14.0. macOS 13 is not supported.
- The app is not sandboxed; it accesses arbitrary paths with full user permissions.
- `NSWorkspace.recycleURLs:completionHandler:` is used for trash (not `NSFileManager.trashItemAtURL:`), so Finder's trash animation plays.
