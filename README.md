# files

A minimalist macOS file manager written in Objective-C + AppKit.

## Features

- List-view browser with Name, Size, Kind, Permissions and Date Modified
  columns; click a header to sort (folders first, Finder-style name order),
  right-click the headers to show or hide columns (every list follows)
- Auto-fit columns (View ▸ Auto-Fit Columns, on by default) and optional
  double-height rows with larger icons (View ▸ Large Rows)
- Single- or dual-pane browsing (View ▸ Dual Pane, ⇧⌘2; Tab switches panes)
- Bookmarks bar (Home, Desktop, Downloads, Documents, Applications, Trash);
  ⌘D or the ★ button adds the current folder, and right-click ▸ Add to
  Bookmarks on a folder in the list adds that folder (before Trash, which
  is always last); right-click a bookmark to remove it. View ▸ Show
  Bookmarks Bar (on by default) hides or shows it in every window
- Quick Look: Space previews the selection (Space or Esc closes it; the
  arrow keys move through the list and the preview follows)
- Collapsible info sidebar with a Quick Look thumbnail and file details
- Get Info panel: size, dates, owner/group, editable permissions, Locked
  flag, rename, and optional SHA-256 / MD5 checksums
- Git folders: the top folder of a git working tree shows its usual folder
  icon with a git badge centered on it. Inside a repository the list gains
  a Git column that reads "tracked" for every file git tracks (including
  newly added ones) and every folder containing one, and is blank for
  untracked and ignored items; it updates when the index changes (add, rm,
  commit, checkout) and is filled in just after the list appears, so large
  repositories never hold up a folder. Git features need Xcode or the
  Command Line Tools and are off without them. The repository's Get Info
  panel adds a Git section: the current branch, whether it is pushed
  (compared with its upstream as of the last fetch — commits
  ahead/behind, no upstream, detached HEAD), and the remote URL (the
  upstream's remote, else origin)
- Copy, cut and paste, and drag and drop (moves by default; hold ⌥ to
  copy), with a progress panel (speed graph, transfer log, cancel), Keep
  Both / Replace prompts, and optional SHA-256 verification (View ▸
  Validate Copies with SHA-256). View ▸ Simple Copies (off by default)
  skips the panel: transfers run silently, keeping both on name clashes,
  and only errors are shown. Copies use APFS clones when possible and
  keep extended attributes, tags, ACLs, the Locked flag and dates; nothing
  at the destination is replaced until the new copy is complete. With
  validation on, each file is checked as soon as it is copied and the copy
  stops at the first mismatch; APFS clones share the original's data, so
  they are not re-read
- Move to Trash, Empty Trash, New Folder and New File (File menu, right-click,
  or the toolbar's + button), inline rename (Return; the name
  without its extension is selected, ready to type)
- App bundles open like folders; right-click ▸ Run Application launches one
- Symbolic links are followed (a link to a folder opens that folder)
- Opening a disk image (.dmg, .iso, …) mounts it and opens its volume in a
  new window; password-protected or licensed images are handed to the
  system's DiskImageMounter to ask, then open the same way
- Spotlight search by name, in the current folder and its subfolders or
  across the whole Mac (the search field's magnifying-glass menu: This
  Folder / This Mac; the empty field shows which); the first 5,000 matches
  are shown, and the status bar says when there are more
- View ▸ Show Folder Sizes (off by default; also in Preferences): the Size
  column shows each folder's total — every file inside it, at any depth,
  added up (symbolic links not followed, other volumes not entered).
  Totals are counted in the background, one folder at a time, and fill in
  as they finish ("…" until then); sorting by Size uses them. They are
  kept while you stay in the folder; Reload counts them again
- Live updates when the current folder changes; a folder that cannot be
  read (no permission, a disconnected server) says so in the status bar.
  Folders are listed in the background, so a slow or unresponsive network
  folder never freezes the window
- View ▸ Show Finder After Archive Operations (off by default) keeps
  Archive Utility's archive-reveal-after / dearchive-reveal-after in step
  with the menu (checked at every launch, including the first), so by
  default expanding or creating an archive does not pop open a Finder window
- Mounts menu: mounted volumes, then cloud storage (iCloud Drive and
  File Provider accounts such as Google Drive); Go menu: Home, Desktop,
  Downloads, Documents and Trash
- An All Mounts panel with per-volume unmount; at the root
  of an unmountable volume (external disk, disk image, network share) a
  floating ⏏ button unmounts it (the status bar confirms), and any window
  showing it moves to /Volumes. If files on it are open, a sheet lists them
  (and the apps using them) and the volume unmounts automatically once
  they are closed
- Default file viewer in place of Finder: "Show in Finder" from other apps
  opens Files; setting Preferences ▸ Default file browser to Finder undoes
  every change (see Replacing Finder)
- Preferences window (Files ▸ Preferences…, ⌘,): every View-menu
  preference, the default file browser (Files or Finder), and Keep Files
  running for faster startup (see Keeping Files running)
- About Files shows the version (from the `VERSION` file), build date,
  and links to camb.io and the license
- Address bar (accepts `~` and relative paths), back/forward/up, Open in
  Terminal, show/hide hidden files

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

## Installation

```sh
make install
```

This builds the app bundle and copies it to `~/Applications/files.app` (per-user; no `sudo` needed). Re-running `make install` replaces the previous copy.

To check a build first, `make test` runs the copy-engine tests (see BUILD.md).

## Full Disk Access

Files expects Full Disk Access (to show protected folders such as the Trash
and to change Archive Utility's settings). On launch it checks, and if access
is missing it explains how to grant it: System Settings ▸ Privacy & Security ▸
Full Disk Access, turn on Files (or add `~/Applications/files.app` with +),
then Quit & Reopen.

The build signs with your first "Apple Development" certificate if you have
one (`security find-identity -v -p codesigning`), so the grant survives
rebuilds and `make install`. Without a certificate it falls back to an
ad-hoc signature, which macOS ties to a single build — the grant then has
to be given again after each install. To choose a specific identity:

```sh
make install CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

## First run

```sh
make run
```

Or double-click `files.app` in `~/Applications` after installing.

## Replacing Finder

On first launch Files makes itself the default file viewer. It does not
replace or disable Finder, which macOS still needs. Instead it changes four
settings:

| Setting | Files sets | Effect |
|---------|------------|--------|
| `NSGlobalDomain NSFileViewer` | `com.salt.files` | "Show in Finder" / "Reveal in Finder" in other apps (browser downloads, editors, `open -R`) opens Files, with the item selected in its folder |
| `com.apple.finder CreateDesktop` | `false` | Finder draws no desktop icons |
| `com.apple.finder QuitMenuItem` | `true` | Finder ▸ Quit Finder exists |
| LaunchServices `LSHandlers` entry for `public.folder` | `com.salt.files` | Folders opened from other apps (`open ~/Downloads`, Dock folders, Spotlight folder results) open in Files, **after you log out and back in** |

Files quits Finder when it changes Finder's settings. Finder only reads
them at launch. It stays quit until something asks for it (its Dock icon,
the Dock's Trash, AirDrop, and so on), and then runs without desktop icons.
Files also turns Archive Utility's "reveal in Finder" off by default
(View ▸ Show Finder After Archive Operations).

Files records each setting's original value (or that it was not set)
before changing it. Every launch re-checks the settings and puts back any
that something else reset.

macOS refuses to change the default app for folders through its API.
Files therefore writes the LaunchServices setting directly, the way
ForkLift does (the `com.apple.launchservices.secure` preferences).
LaunchServices reads it only at login. After logging back in, check it
with:

```sh
swift -e 'import AppKit; print(NSWorkspace.shared.urlForApplication(toOpen: .folder)!)'
```

The result should end in `files.app/`. If it still shows Finder, this
macOS version ignores the setting. Everything else keeps working, and
folders keep opening in Finder.

A revealed folder opens to show its contents. macOS sends reveals as plain
"open" requests, so Files can't tell them apart. Hidden items are only
selected while hidden files are shown.

Some things still go to Finder, because macOS gives other apps no way to
take them:
- double-clicking a folder inside a Finder window
- the Finder and Trash icons in the Dock
- AirDrop and Connect to Server
- AppleScripts that name Finder

### Uninstalling

Before removing Files, open **Files ▸ Preferences…**, set **Default file
browser** to **Finder**, and turn off **Keep Files running for faster
startup** so it is no longer a login item. Files writes every recorded setting back exactly as it was,
turns Archive Utility's reveal back on, and relaunches Finder. Then quit
Files, delete `~/Applications/files.app`, and log out and back in so
LaunchServices sends folders to Finder again. Setting Default file browser
back to Files switches back.

## Keeping Files running

By default Files quits when its last window closes, so the next "Show in
Finder" or opened folder has to launch it again. Turn on **Preferences ▸
Keep Files running for faster startup** (off by default) to have Files
behave like Finder:

- it stays open, without windows, after the last window closes, so the
  next window appears instantly
- clicking its Dock icon with no window open opens a home-folder window
- it is added to your login items and starts at login without opening a
  window (if you have turned Files off in System Settings ▸ General ▸
  Login Items, it asks you to turn it back on)
- each time it is used again with no windows open it repeats its launch
  checks: Full Disk Access, and the Finder / Archive Utility settings it
  manages

Only opening windows gets faster; browsing within a window is the same.
Turning the option off removes the login item. The login item points at
the copy of Files that was running when you turned the option on, so turn
it on from `~/Applications/files.app`, not from a build in the project
folder.

## Keyboard shortcuts

| Action         | Shortcut           |
|----------------|--------------------|
| Copy           | ⌘C                 |
| Cut            | ⌘X                 |
| Paste          | ⌘V                 |
| New Window     | ⌘N                 |
| Preferences    | ⌘,                 |
| Find (search)  | ⌘F                 |
| New File       | ⌥⌘N                |
| Move to Trash  | ⌘⌫                 |
| Add Bookmark   | ⌘D                 |
| Open in Terminal | ⌘⇧T              |
| Dual Pane      | ⌘⇧2                |
| New Folder     | ⌘⇧N                |
| Get Info       | ⌘I                 |
| Select All     | ⌘A                 |
| Rename         | Return             |
| Back           | ⌘[                 |
| Forward        | ⌘]                 |
| Home           | ⌘⇧H               |
| Desktop        | ⌘⇧D               |
| Downloads      | ⌘⇧L               |
| Documents      | ⌘⇧O               |

## License

BSD 3-Clause License. Copyright © 2026 Ian Campbell. See `LICENSE`.
