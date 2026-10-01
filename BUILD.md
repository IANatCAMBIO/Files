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
| Quartz          | Quick Look panel (Space in the file list)    |
| UniformTypeIdentifiers | Per-file-type icon lookup (icon cache) |
| ServiceManagement | Login item for Keep Files running (`SMAppService`) |

At run time Files runs `/usr/bin/git` (Xcode or the Command Line Tools) for
the Git column and Get Info's branch and push state. Without either, the git
features are simply off: Files checks once with `xcode-select -p` and never
runs git, so macOS does not offer to install the tools. It also runs `lsof`
(what keeps a volume busy), `hdiutil` (disk images) and, for Archive
Utility's sandboxed settings only, `defaults`.

The C library's `copyfile(3)`, `renamex_np(2)` and CommonCrypto (SHA-256 / MD5)
are part of libSystem and need no extra linking.

## Build targets

| Target          | Command         | Description                            |
|-----------------|-----------------|----------------------------------------|
| Build (default) | `make`          | Compiles and assembles `Files.app`     |
| Run             | `make run`      | Builds then opens the app with `open`  |
| Install         | `make install`  | Replaces `~/Applications/Files.app` with the new build |
| Test            | `make test`     | Builds and runs the copy-engine tests (`tests/`) |
| Clean           | `make clean`    | Removes `build/` and `Files.app`       |

`make test` links each `tests/*_test.m` against the app's objects (all but
`main.o`) and runs it. `file_ops_test` exercises the copy engine on a scratch
folder in `$TMPDIR` and on a small HFS+ disk image it creates and mounts
(`hdiutil`): locked files and folders, Keep Both, Replace, duplicate in
place, copy into itself, same-volume and cross-volume moves, and SHA-256
validation (APFS clones are not hashed; copies to another volume are). It
cleans up after itself, prints one line per check and exits non-zero on a
failure. `make clean` and `make test` skip the keychain lookup for the
signing identity.

## Output

The build produces `Files.app/` in the project root:

```
Files.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── Files          ← compiled binary
    └── Resources/
        └── folder.png, documents.png, ribbon.png, git96.png  ← git badge
```

The Makefile copies every `.png` and `.icns` in `images/` into `Resources/`,
so adding an image there is all it takes to bundle it; the app loads it by
name (`NSBundle pathForResource:ofType:`).

## Version and build date

The version lives in the `VERSION` file at the project root (one line,
e.g. `1.0`). When `make` assembles the bundle it copies
`resources/Info.plist` and writes into the copy:

| Key | Value |
|-----|-------|
| `CFBundleShortVersionString`, `CFBundleVersion` | contents of `VERSION` |
| `FilesBuildDate` | time the bundle was assembled, UTC, ISO 8601 |

Files ▸ About Files shows them as "Version 1.0 (built <date>)", with the date in
local time. To release a new version, edit `VERSION` and run `make`; editing
it is enough to rebuild the bundle. The build date is refreshed whenever the
bundle is reassembled (any source change, `Info.plist` or `VERSION`), not on
a no-op `make`.

## Incremental builds and compiler checks

- Header dependencies are tracked automatically (`-MMD -MP` writes `build/*.d`),
  so editing a header rebuilds every `.m` that includes it. Editing the
  `Makefile` rebuilds everything. A plain `make` is always enough; `make clean`
  is never required for correctness.
- `-Werror=unguarded-availability` makes it a build error to call an API newer
  than the deployment target (macOS 14.0) without an `@available` check.
  Clang cannot check messages sent to `__kindof` receivers (for example
  `NSApp` or `+[NSApplication sharedApplication]`), so review those by hand.
- `-Wno-unused-parameter`: the only unused parameters are ones callback
  signatures require (blocks, FSEvents callbacks, notification handlers).

## Source layout

```
src/
├── main.m                  — entry point
├── app_delegate.h/.m       — app lifecycle (incl. Keep Files running and
│                             its login item), menu bar, Mounts menu
├── main_window.h/.m        — window controller: toolbar, split views, one or
│                             two browser panes, Go-menu and view-preference
│                             actions
├── browser_view.h/.m       — file list (NSTableView): listing, filtering and
│                             sorting off the main thread, FSEvents watcher,
│                             Git column, Spotlight search, history
├── bookmarks_bar.h/.m      — bookmarks strip above the browser, shared by
│                             every window; app-wide Trash watcher
├── git_info.h/.m           — git working trees: tracked names, branch and
│                             push state, the git folder badge
├── info_sidebar.h/.m       — collapsible Quick Look / details sidebar
├── info_panel.h/.m         — Get Info panel (permissions, lock, hashes)
├── file_ops.h/.m           — pasteboard, copy/move engine (copyfile +
│                             rename, staged commits), trash, rename, mkdir
├── copy_progress.h/.m      — copy progress panel and conflict prompts
├── speed_graph.h/.m        — bounded transfer-speed graph
├── file_hash.h/.m          — single-pass, cancellable SHA-256 / MD5
├── mounts_panel.h/.m       — All Mounts panel (mount table read off the
│                             main thread; per-volume unmount)
├── volume_manager.h/.m     — mounted-volume list, unmount, disk images
├── default_viewer.h/.m     — takes over from Finder as default file viewer
│                             (NSFileViewer, Finder settings) and restores
│                             the recorded originals
├── prefs_window.h/.m       — Preferences window; the View-menu preference
│                             list both it and the menu are built from
└── util.h/.m               — shared helpers: preference keys, other apps'
                              preferences (CFPreferences, or `defaults` for
                              sandboxed apps), running tools with a timeout,
                              the background queue, standard folder URLs,
                              the icon cache, size/date formatting, alerts
tests/
└── file_ops_test.m         — copy-engine tests (`make test`)
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
