# Pre-release code review — 2026-09-30

Scope: all of `src/` (~7.7k lines Obj-C), Makefile, README.md, BUILD.md, Info.plist, at commit 5dd0a24.
Focus: (1) dead/duplicated code, (2) documentation, (3) performance / use of macOS services, (4) RAM/resources.
Correctness bugs found along the way are listed first because several are release blockers.

Severity: **H** = fix before release, **M** = should fix, **L** = cleanup.

---

## Status (2026-09-30)

**Done in the second pass (sections 1–4):**
- Dead code removed: `sidebar.*`, `ribbon.png`, unused APIs, the macOS 11/12 fallbacks, `initWithCoder:` overrides and singleton `dealloc`s.
- Duplicates consolidated into `util.*`: settings keys, standard folder URLs, byte/rate/date formatting (now base-1000 everywhere) and error alerts. Hashing is consolidated in `file_hash.*`: a single-pass, cancellable, `F_NOCACHE` SHA-256/MD5.
- Navigation now goes through one `load_location:`, which fixes the stale search results and wrong Empty Trash button after Back/Forward.
- Performance:
  - Cells use cached formatters, an icon cache, and prefetched permission modes (no `lstat` per cell).
  - The folder watcher ignores events below the shown folder and coalesces the rest.
  - Folders are listed on a background queue.
  - Auto-fit runs only on navigation or toggle, and measures at most 2000 rows.
- AppKit instead of hand-rolled UI: `NSSplitViewController` for the sidebar; plain `NSToolbarItem`s and `NSSearchToolbarItem`; `NSWorkspace` for Terminal; `menuNeedsUpdate:` for Devices.
- Unmount now unmounts only the selected volume.
- Memory:
  - The speed graph's buffer is bounded and decimated.
  - The transfer log is capped at 1000 lines, and main-queue progress updates are throttled.
  - Quick Look thumbnails are requested at the right size.
  - The Info panel cancels its hash when the selection changes.
  - The back/forward history is capped at 100.
- Docs: README and BUILD.md refreshed; the wrong comments fixed; every function has a comment block.

**Follow-ups done:** app bundles stay browsable as folders by design, with a
context-menu "Run Application". Inline rename now edits the Name cell in
place, with the base name pre-selected. Trash is always the last bookmark;
the saved list is only rewritten when that isn't already true.

Symbolic links are followed like Finder aliases: a link to a folder shows the
target folder, and a broken link reports an error.

## 0. Release blockers

**Status (2026-09-30, uncommitted):** B1–B7, B9–B12 fixed. B8 resolved by dropping macOS 13 support: the deployment target, Info.plist and docs now say 14.0. `make install` now installs to `~/Applications` and replaces the old copy instead of nesting inside it. Sections 1–5 below are still open. The one exception is the copy engine: it now uses `copyfile(3)`/`rename(2)` (see section 3).

| # | Where | Issue |
|---|-------|-------|
| B1 | `browser_view.m:1461` | **Build is broken.** Drag-drop calls `run_copy_srcs:…cancel_flag:known_total:progress:completion:` which doesn't exist (real selector has `conflict:` and no `known_total:`). The shipped `files.app` only links because `build/browser_view.o` was stale — the Makefile doesn't track header deps (see M1). At runtime a drop would crash with unrecognized selector. Fix: route drop through `[FilesCopyProgress begin_copy:…]` (also gives drops progress/cancel/conflict prompts). |
| B2 | `file_ops.m:201,223-231` | **Replace destroys the existing file first.** `open(dst, O_TRUNC)` wipes it; on cancel/I/O error `unlink(dst)` removes it → old and new both lost. Write to a temp file in the dest dir, then `renamex_np`. |
| B3 | `file_ops.m:386-396` + `:201` | **Paste into the same folder + "Replace" empties the source** (dst == src → clone fails EEXIST → `O_TRUNC` truncates the source inode, copies 0 bytes; on cut the file is then deleted). Skip when dst path == src path. |
| B4 | `file_ops.m:245-255` | **Cut deletes the source even when SHA-256 validation fails.** Delete only when `ok`. All `removeItemAtURL:src … error:nil` results (182, 254, 444) are ignored. |
| B5 | `file_ops.m:281-284,405-408,439-446` | **Cut can delete files that were never copied.** Unreadable subfolder → `contentsOfDirectoryAtURL:error:nil` returns nil silently → final loop `removeItemAtURL:` removes the whole source tree. |
| B6 | `file_ops.m:384,401-414` | Existing destination **directory is merged silently**; every colliding child is overwritten via `O_TRUNC` with no prompt. |
| B7 | `file_ops.m:270-290` | Copying a folder into itself/its subfolder recurses without end (no ancestor check in paste; drop only checks same parent). |
| B8 | `app_delegate.m:26` | `[NSApp activate]` is macOS 14+, but min target is 13.0 → **crash at launch on Ventura**. Guard with `@available` or raise the minimum. |
| B9 | `app_delegate.m:213-216` | Edit menu uses custom `cut_action:/copy_action:/paste_action:/select_all_action:` instead of `cut:/copy:/paste:/selectAll:` → **⌘C/⌘V/⌘X/⌘A don't work in the address bar, search field or rename field**; in the rename field ⌘C copies *files*. No Undo/Redo. |
| B10 | `browser_view.m:1031-1035` | Plain Delete (no ⌘) trashes the selection. README documents it, but it's an easy accidental-trash; Finder requires ⌘⌫. Comment says "without modifiers" but modifiers aren't checked at all. |
| B11 | `info_panel.m:562,571` | Permissions popup reads mode with `lstat()` but writes with `chmod()` (follows symlinks) → editing a symlink's perms writes a wrong mode onto the target. |
| B12 | `info_panel.m:514-517` | "Locked" checkbox is driven by `NSURLIsWritableKey`, so any read-only file shows Locked; unchecking clears a `uchg` flag that was never set. Use `NSURLIsUserImmutableKey`. |

---

## 1. Dead and duplicated code

### Dead
- **`sidebar.m` + `sidebar.h` (406 lines) are entirely unused** — nothing imports `sidebar.h`, but `$(wildcard src/*.m)` still compiles and links it. Delete. (Also removes a third copy of volume enumeration and a second eject+alert flow.)
- `file_ops`: `paste_to_directory:progress:hash_validate:completion:` has no callers (and duplicates the other paste variant); `pasteboard_is_cut` / `urls_from_pasteboard` are only used internally → make static.
- `known_total` / pre-scan remnants: `total_total` hard-coded to 0 (`file_ops.m:431`), so the ETA block `copy_progress.m:467-479` can never run. Either compute totals in `collect_pairs` or delete the ETA code.
- Progress block `bps` param always 0; `chunk_ctx_t.cancel` never read; `copy_progress is_cancelled` unused; `speed_graph current_bps` + ivar unused; unreachable `count == 1` branch in `speed_graph.m:110-115`.
- `browser_view search_text` is never assigned → text-filter branch in `apply_filter` (`:509,519-526`) is dead.
- Prefetched-but-unread keys: `NSURLFileAllocatedSizeKey`, `NSURLIsSymbolicLinkKey`, `NSURLCreationDateKey` (`browser_view.m:21-26`).
- All `@available(macOS 11/12)` checks + text fallbacks are unreachable at a 13.0 target (`main_window.m:94,515,530,560,587,604,621,636,654`).
- `initWithCoder:` overrides with no nibs: `browser_view.m:90`, `main_window.m:70`, `bookmarks_bar.m:17`, `mounts_panel.m:113`.
- Singleton `dealloc`s that never run: `volume_manager.m:45`, `mounts_panel.m:153`.
- `info_panel.m:225-229,299-302`: "Name:" row produces a blank duplicate row + dead `value_fields[]` scaffolding.
- `main_window.m:348-357` `_in_toggle_dual` double-fire guard (push-on/push-off doesn't double-fire; find the real cause); `observing_responder` flag redundant (`:363-366,410-416`).
- Small: `browser_view.m:274-281` `viewDidMoveToWindow`; redundant main-queue hop `browser_view.m:1469`; `app_delegate.m:219-222`; `bookmarks_bar.m:138,309`; `main.m:18`; `main_window.m:333,846`; `browser_pane.m:3-9,70,86` hand-written ivars/getters.
- Unused asset: `ribbon.png` (40 KB) is committed but never referenced.
- `bookmarks_bar.m:62-70` "migration" re-adds Trash on every launch → user can't remove it.

### Duplicated → consolidate into one helper each
| Duplicate | Locations | One source of truth |
|---|---|---|
| Byte formatting (and **inconsistent**: copy panel uses base-1024, rest of app base-1000) | `browser_view.m:739`, `info_panel.m:470`, `info_sidebar.m:155`, `mounts_panel.m:356,528`, `copy_progress.m:36-46`, `speed_graph.m:229-238,268-277` | `files_format_bytes()` on a `dispatch_once` `NSByteCountFormatter` (or `+stringFromByteCount:countStyle:`) |
| Date formatting | `browser_view.m:760`, `info_panel.m:483`, `info_sidebar.m:172`, `copy_progress.m:260` | `files_format_date()` with static formatter(s) |
| File hashing read loops (3 loops; info panel reads file **twice** for SHA+MD5) | `file_ops.m:96-132`, `file_hash.m:18-51`, `info_panel.m:80-101` | one `file_digests(path, sha, md5, cancel)` in `file_hash.m`, single F_NOCACHE pass |
| Directory walk | `file_ops.m:277-290` vs `401-414` | `collect_pairs` called once per top-level item |
| Two copy entry paths (drop = no UI, paste = panel) | `browser_view.m:1461` vs `copy_progress` | always `FilesCopyProgress begin_copy:` |
| NSAlert error blocks (~15) | `browser_view.m:1096,1115,1135,1308,1471`, `info_panel.m`, `mounts_panel.m`, `copy_progress.m` | `show_error(title, err, window)` using `beginSheetModalForWindow:` |
| `~/.Trash` built by hand ×5; Desktop/Downloads/Documents ×2 | `bookmarks_bar.m:53,75-79,233`, `browser_view.m:327,506,827,1190-1210` | `NSFileManager URLForDirectory:` helper |
| NSUserDefaults key literals (`files.show_hidden_files` ×4, `files.auto_fit_columns` ×5, `files.copy.hash_validation` ×4, `files.show_hashes` ×3) | across files | `extern NSString *const` in one header |
| `navigate_to:` body copied into `go_back`/`go_forward` — **and the copies miss steps** (don't stop Spotlight search → stale results; don't update Empty Trash button) | `browser_view.m:336-371` | private `load_location:` |
| "open file vs navigate" check | `browser_view.m:991-1004,1048-1060` vs `291-300` | just call `navigate_to:` |
| Stop-query + remove observers ×3 (and `dealloc` doesn't do it) | `browser_view.m:304,560,598` | `stop_search_query` |
| Pane wiring blocks / sidebar refresh / active-pane switch | `main_window.m:290-298` vs `394-401`, `1010-1018` vs `941-950`, `451-466` vs `806-823` | `wire_pane:`, `set_active_pane:` |
| `FilesBrowserPane` pass-through forwarding (navigation/info handlers, navigate_to, current_url, selected_urls) while other handlers are set on `pane.browser` directly | `browser_pane.m:31-41,94-120` | drop the forwarding layer |
| Mounts reload sequence ×4 (inconsistent; loses sort) and cell text logic ×2 | `mounts_panel.m:415-488`, `319-334` vs `528-540` | `reload_table`, reuse `cell_text_for_col:` |
| Copy SHA / Copy MD5 actions | `info_panel.m:590-616` | one action keyed by `sender.tag` |
| Toolbar allowed/default identifier arrays | `main_window.m:470-491` | one static array |
| Volume enumeration | `app_delegate.m:104`, `mounts_panel.m:282`, `sidebar.m:157` | `FilesVolumeManager` only (sidebar deleted) |

---

## 2. Documentation

**Project/build docs**
- `BUILD.md` source layout lists 8 modules; there are 15 (missing `browser_pane`, `bookmarks_bar`, `copy_progress`, `speed_graph`, `file_hash`, `info_sidebar`, `mounts_panel`; lists dead `sidebar`). Framework table omits `QuickLookThumbnailing`.
- `README.md` features list is out of date (no dual-pane, bookmarks bar, info sidebar, copy progress/hash validation, mounts panel, Spotlight search). Mentions "Sidebar with Favorites/Devices" which is the dead code.
- BUILD.md says tested on 13 — it can't launch there (B8).
- Makefile has no `test` target (fine if intentional — say so in BUILD.md).

**Missing function comment blocks** (style rule: every function): `browser_view.m` 90, 269, 274, 373-375, 871, 974, 1008, 1014; `browser_pane.m` 70, 86; `main_window.m` 70, 470, 481, 1064; `bookmarks_bar.m` 17; `info_sidebar.m` 30; `mounts_panel.m` 113, 153, 492, 500; `volume_manager.m` 45; `speed_graph.m` 78; typedef structs in `copy_progress.m:10-24`. Many existing blocks omit Inputs/Output (e.g. `build_toolbar`, `wire_up`, split-view delegates, `build_table`, `copy_action:`, `update_status_bar`, `shared`, `can_eject_volume:`).

**Comments that are wrong** (worse than missing)
- `file_ops.h:39` "progress panel for transfers >= 10 MB" — always shown.
- `copy_progress.h:8-10`, `copy_progress.m:276-278,345-347` — "indeterminate bar", "size pre-scan", "fills bar to 100%": none exist.
- `copy_progress.m:8` SPEED_RING "~250 ms apart" — actually one per 1 MB chunk (~0.3 ms at SSD speeds).
- `copy_progress.m:534-535` says conflict block returns Cancel when panel gone — it returns KeepBoth.
- `speed_graph.m:50` "avg_bps … not stored" — it is stored and drawn.
- `browser_view.m:34-38` "debounced", "retained reference" — neither true.
- `browser_view.m:769` "visible rows" — measures all rows.
- `browser_view.h:4-5` "status bar" — view has none; `browser_view.h:104` "safe from any context" vs .m "main thread only".
- `browser_pane.h:15,21-23` 2pt accent border — there's no `drawRect:`; it dims via alpha.
- `main_window.m:702-704` address bar "resolves relative paths / shakes field" — neither implemented.
- `main_window.m:832-852` "springs back to last width" — always 180.
- `info_sidebar.h:19-24` "directories excluded from total" — any dir in selection shows "—".
- `bookmarks_bar.h:5-6` default list omits Trash; `bookmarks_bar.m:14` "weak ref" is strong.
- `mounts_panel.h:5-6` "eject button for removable volumes" — it's Unmount and ejects the whole disk.
- `browser_view.m:671-672` stray `/*` (compiler `-Wcomment` warning).

**Style**: `kCamelCase` constants (`kColName`, `kPanelWidth`, `kCutFlagType`…), `VCenterCell`, and PascalCase typedefs/classes conflict with the snake_case rule. ObjC class names are a reasonable exception — decide once and write it down.

---

## 3. Performance & use of macOS services

**High impact**
- **Per-cell formatter allocation**: new `NSByteCountFormatter` + `NSDateFormatter` for every Size/Date cell (`browser_view.m:739,760`). `NSDateFormatter` creation is expensive; with auto-fit this runs rows × columns on every reload.
- **Recursive, un-debounced FSEvents watcher** (`browser_view.m:40-56,240-248`): `kFSEventStreamCreateFlagFileEvents` on the listed dir fires for anything beneath it; sitting in `~` reloads + auto-fits constantly. Each event queues its own `dispatch_after` (stacks, not debounced). Use a `DISPATCH_SOURCE_TYPE_VNODE` source on the directory (non-recursive, one fd), or filter `event_paths` to `current_dir` and coalesce with a pending flag.
- **Auto-fit measures every row × column on every reload** (`browser_view.m:772-803`) including watcher/Spotlight updates, with the wrong font for Permissions. Measure visible rows only, only on navigation/toggle.
- **Hand-rolled copy engine** (`file_ops.m:154-258`) vs `copyfile(3)`: current code loses xattrs, ACLs, Finder tags, quarantine, resource forks, dates; follows symlinks (copies target contents); moves on the same volume via clone+delete per file instead of one `rename(2)`. Use `renamex_np(…, RENAME_EXCL)` for moves (fall back on EXDEV) and `copyfile(COPYFILE_ALL|COPYFILE_RECURSIVE|COPYFILE_CLONE|COPYFILE_NOFOLLOW_SRC)` with `COPYFILE_STATE_STATUS_CB` for progress/cancel. Deletes `copy_file_chunked`, `chunk_ctx_t`, `chunk_callback`, duplicated walk. Also fixes B2/B6/B7 largely.
- **Main-queue flood during copy**: `dispatch_async` to main per 1 MB chunk (thousands/sec on fast SSDs) (`copy_progress.m:420-481`). Throttle to ~100-250 ms on the copy thread.

**Medium**
- Directory listing is synchronous on the main thread (`browser_view.m:400-425`) — hangs on large/network folders. Enumerate on a background queue with a generation counter.
- `lstat()` per Permissions cell on main thread (`browser_view.m:751`) — prefetch `NSURLFileSecurityKey`.
- `NSWorkspace iconForFile:` per Name cell, uncached (`browser_view.m:933`) — `NSCache` keyed by UTI; per-path only for packages/custom icons.
- Spotlight results built with bare `fileURLWithPath:` → every cell stats lazily; array rebuilt per update; hidden-file filter not applied; column-header click during search replaces results with the directory listing (`browser_view.m:619-641,966-968`).
- Info panel hashing isn't cancellable when selection changes (keeps hashing a multi-GB file); reads file twice (SHA + MD5).
- Hash validation re-reads a destination still in page cache (proves little) and `close()` unchecked; add `F_FULLFSYNC`/`fsync`, and `F_NOCACHE` in `file_sha256`.
- "Unmount" uses `unmountAndEjectDeviceAtURL:` → ejects the **whole physical disk**, blocks a global-queue thread, and never enables for network mounts. Use `-[NSFileManager unmountVolumeAtURL:options:completionHandler:]`.
- Mounts "Free" from `statfs` ignores APFS purgeable space → disagrees with Finder; use `NSURLVolumeAvailableCapacityForImportantUsageKey`.
- Info sidebar / panel / volume manager do many single `getResourceValue:` calls; use one `resourceValuesForKeys:` / prefetch keys in `mountedVolumeURLsIncludingResourceValuesForKeys:`.
- Empty Trash deletes synchronously on main thread and skips hidden files (`browser_view.m:830-838`).
- Packages (`.app`) treated as folders (double-click enters the bundle; Kind "Folder"); symlinks to dirs open in Finder instead of navigating. Prefetch `NSURLIsPackageKey`, resolve symlinks.
- Sort comparator string-compares the key and does 2 resource lookups per comparison; `compare:nil` can throw; uses `localizedCaseInsensitiveCompare:` (Finder uses `localizedStandardCompare:` → file2 < file10); Permissions column sorts by name.

**Leverage AppKit instead of hand-rolling**
- Info sidebar collapse: ~80 lines of manual `NSSplitView` delegate code → `NSSplitViewController` + `NSSplitViewItem` (collapse, min thickness, autosave for free).
- Toolbar: custom-view `NSButton`s have no overflow menu representation → plain `NSToolbarItem`s, `NSSearchToolbarItem`, `NSToolbarItemGroup` for back/forward; set `window.representedURL` for proxy icon + ⌘-click path menu.
- Inline rename: manual field + triple coordinate conversion (misplaced, doesn't scroll) → `-[NSTableView editColumn:row:withEvent:select:]`.
- Open Terminal via `NSTask /usr/bin/open` → `NSWorkspace openURLs:withApplicationAtURL:`.
- Devices menu → `menuNeedsUpdate:` delegate instead of notification + eager rebuild.
- Trash icon → watch `NSTrashDirectory` once instead of `dispatch_after(0.5)` polls on navigation (which currently fire while the Empty Trash sheet is still open).
- `OSAtomicCompareAndSwap32` (deprecated) + `volatile int32_t` → C11 `atomic_int`.
- `CC_MD5` deprecated since 10.15 — keep in one place with a local pragma.

---

## 4. RAM / resources

- `speed_graph` `_samples` grows unbounded (one double per 1 MB chunk) and `drawRect:` is O(n) per frame; `realloc` unchecked → fixed ring (e.g. 512) with pairwise-max decimation.
- Copy transfer log: one line per file, unbounded `NSTextStorage`, `scrollToEndOfDocument` each time → cap (e.g. last 1000 lines) / batch.
- Info sidebar requests Quick Look thumbnails at ~4× the needed pixels on Retina (size already × scale **and** `scale:` passed) (`info_sidebar.m:230-237`); stale-request check compares URLs not requests.
- Info sidebar thumbnail/QL request kept alive when sidebar is collapsed (`main_window.m:853-858` should call `clear`); `documents.png` reloaded from disk on every multi-select.
- Back/forward stacks unbounded; navigating to the current dir pushes a duplicate.
- Background hash jobs pile up (not cancelled) — CPU + I/O.
- `browser_view dealloc` stops the watcher but not the `NSMetadataQuery`/observers.
- `fs_event_callback`'s `dispatch_after` block strongly captures the view (not a cycle, but outlives teardown; use weak).
- Retain cycles: none found — stored handler blocks consistently capture `self` weakly. 

---

## 5. Build system

- **M1 — FIXED** (`-MMD -MP` + objects depend on the Makefile; `-Werror=unguarded-availability` added, though it cannot see `__kindof` receivers like `NSApp`, so it would not have caught B8). Was: Makefile has no header dependencies (`build/%.o: src/%.m` only) — header changes don't rebuild dependents; this is exactly how B1 shipped. Add `-MMD -MP` to CFLAGS and `-include $(OBJS:.o=.d)`.
- `-Wno-deprecated-declarations` hides the `OSAtomic*`/`CC_MD5`/other deprecations — drop it and fix/pragma locally.
- `-Wno-unused-parameter` hides unused params (e.g. `hash` in `copy_progress.m:84,117`).
- ~~Add `-Werror=unguarded-availability`~~ done (see M1).
- **`make install` is broken on re-install**: `cp -r files.app /Applications/files.app` when the target exists copies *into* it (`/Applications/files.app/files.app`), so the installed binary never updates (verified). `rm -rf` the target first, or use `ditto`.
- `$(BUNDLE)` depends on resources but not `ribbon.png` (unused anyway — delete).

---

## Suggested order of work
1. B1–B12 (blockers), plus Makefile header deps (M1) and `-Wunguarded-availability`.
2. Replace copy engine with `renamex_np` + `copyfile(3)` — removes most of `file_ops.m`'s custom I/O and fixes B2/B3/B6/B7 and metadata loss.
3. Delete dead code (`sidebar.*`, unused APIs, availability fallbacks, `ribbon.png`).
4. Shared helpers: formatting, alerts, well-known URLs, defaults keys, hashing.
5. Browser performance: static formatters, VNODE watcher, background listing, icon cache, auto-fit on visible rows.
6. AppKit replacements (split view controller, toolbar items, table-native rename).
7. Docs pass: README/BUILD.md refresh, fix the wrong comments, fill missing blocks.

---

# Optimization pass — 2026-10-01

Scope: all of `src/` at commit c2bac09, reviewed for (1) simplicity,
(2) reliability, (3) speed, (4) resource use. Every finding below was
implemented on branch `optimizations`, except where noted.

## Copy engine (`file_ops`, `copy_progress`, `file_hash`)
- **Locked items could not be copied** (copyfile copies `uchg`, so the commit
  rename failed with EPERM and cleanup left hidden `.files-tmp-*` items).
  Folders are unlocked while copyfile fills them (it re-locks them in its
  cleanup pass) and the staged item while it is renamed into place; all
  cleanup uses `remove_tree`.
- SHA-256 validation runs in the copyfile callback as each file lands and
  stops at the first mismatch; APFS clones (`COPYFILE_STATE_WAS_CLONED`) are
  not hashed. `verify_copy` and the `hash_results` dictionary are gone.
  Source and copy are hashed in parallel when on different devices.
- Same-volume moves are one `renamex_np(RENAME_EXCL)`; staging only for Replace.
  (Replace via `RENAME_SWAP` was not adopted: it needs a fallback for volumes
  without swap support, for little gain.)
- Failed rollback renames report where the hidden item now is.
- Into-itself / same-folder checks use `realpath` (case, symlinks).
- `unique_dest_url` uses `lstat` like the rest of the engine.
- Progress and log lines are recorded on the copy thread and picked up by the
  panel's 0.25 s timer (no main-queue hop per file or line).
- `file_digests` sizes its buffer to the file; log arguments are formatted
  only when there is a log.
- `make test` (`tests/file_ops_test.m`) covers the engine.

## Browser (`browser_view`, `main_window`, `bookmarks_bar`)
- Listing, filtering and sorting run on a global queue (the per-pane serial
  queue let one hung network folder block later navigation).
- The Git column is filled in after the listing shows; `git ls-files` reruns
  only when the folder or its index (mtime + size) changed, and its output
  makes one string per child. (Computing "is a git repo" per child in the
  background was not needed once folder icons are cached app-wide.)
- Spotlight results are built, prefetched, filtered and sorted off the main
  thread, capped at 5,000.
- Unreadable folders say so in the status bar.
- Folder-level FSEvents with WatchRoot (one stream per navigation).
- `pending_names` / `pending_rename` replace `reload_directory_then:`.
- One `show_rows` / `resort` path; Show Hidden Files applies to every pane in
  every window; strmode(3); Kind uses the localized type.
- `FilesBrowserPane` removed; `shut_down` on window close.
- One app-wide Trash watcher drives every bar's Trash icon; bookmark bars
  reload when another window saves the list.

## App lifecycle (`app_delegate`, `default_viewer`, `util`)
- `prefs_changed` waits for the first `sync_integrations` (no double syncs or
  stacked Full Disk Access prompts at first launch).
- `run_checks` runs after the first window draws; the Full Disk Access prompt
  appears at most once per run.
- SMAppService, Archive Utility and default-viewer work share one
  utility-QoS serial queue (`files_background_queue`).
- `files_sync_prefs` uses CFPreferences for ordinary domains; the `defaults`
  tool only for sandboxed containers (Archive Utility).
- `files_run_tool` has a timeout.
- Every NSUserDefaultsDidChangeNotification observer runs on the main queue.
  (`default_viewer` still saves its records from the background queue; with
  main-queue observers that is harmless, so it was left as is.)
- The Mounts menu opens a window when none is open.
- Login launches are logged (`[launch] started as a login item`) to confirm
  keyAELaunchedAsLogInItem arrives for the SMAppService login item.

## Panels and helpers
- All Mounts reads the mount table and capacities off the main thread
  (`getmntinfo_r_np`, MNT_DONTBROWSE for volumes).
- lsof / hdiutil via `files_run_tool`; interactive mounts are detected with
  `hdiutil info` instead of re-running attach.
- git is skipped when neither Xcode nor the Command Line Tools is installed.
- Info panel: NSGridView layout (FilesVCenterCell, the name box and frame math
  removed); hashes toggle alone; rename race fixed; fresh URL instead of
  clearing the browser's cached values; Kind for packages.
- Info sidebar: no Quick Look request for plain folders.
- `files_icon_for_url` caches app-wide for list rows and bookmarks; Get Info and
  the sidebar read the item's own current icon (custom icons included).

## Build
- `VERSION :=`; `make clean` / `make test` skip the signing-identity lookup.
- `-Wno-unused-parameter` kept on purpose: every remaining unused parameter is
  required by a callback signature (documented in the Makefile and BUILD.md).

## Follow-up from reviewing this branch
- The Git cache keeps its own tracked set (only a successful git run sets it),
  so a listing abandoned mid-git can no longer leave a folder showing nothing
  tracked; a failed or timed-out `git ls-files` is not cached.
- Table reloads (late git results while sorted by Git, Show Hidden Files,
  search updates) wait for an inline rename to end.
- Items to select after a create or rename are only taken for the folder
  still shown, outside a search; navigation clears them.
- After `shut_down` a browser lists and watches nothing.
- A copy that cannot be re-locked is logged.
- `files_sync_prefs` treats only ENOENT as "no container", so a refused check
  without Full Disk Access never writes a sandboxed app's settings to the
  wrong place.
