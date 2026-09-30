# files

A minimalist macOS file manager written in Objective-C + AppKit.

## Features

- List-view browser with Name, Size, Kind, Permissions and Date Modified
  columns; click a header to sort (folders first, Finder-style name order)
- Optional auto-fit columns (View ▸ Auto-Fit Columns) and double-height
  rows with larger icons (View ▸ Large Rows)
- Single- or dual-pane browsing (View ▸ Dual Pane, ⇧⌘2; Tab switches panes)
- Bookmarks bar (Home, Desktop, Downloads, Documents, Applications, Trash);
  ⌘D or the ★ button adds the current folder (before Trash, which is always
  last), right-click removes one
- Collapsible info sidebar with a Quick Look thumbnail and file details
- Get Info panel: size, dates, owner/group, editable permissions, Locked
  flag, rename, and optional SHA-256 / MD5 checksums
- Copy, cut and paste, and drag and drop (moves by default; hold ⌥ to
  copy), with a progress panel (speed graph, transfer log, cancel), Keep
  Both / Replace prompts, and optional SHA-256 verification (View ▸
  Validate Copies with SHA-256). View ▸ Simple Copies skips the panel:
  transfers run silently, keeping both on name clashes, and only errors
  are shown. Copies use APFS clones
  when possible and keep extended attributes, tags, ACLs and dates; nothing
  at the destination is replaced until the new copy is complete
- Move to Trash, Empty Trash, New Folder and New File (File menu, right-click,
  or the toolbar's + button), inline rename (Return; the name
  without its extension is selected, ready to type)
- App bundles open like folders; right-click ▸ Run Application launches one
- Symbolic links are followed (a link to a folder opens that folder)
- Opening a disk image (.dmg, .iso, …) mounts it and opens its volume in a
  new window; password-protected or licensed images are handed to the
  system's DiskImageMounter to ask, then open the same way
- Spotlight search within the current folder
- Live updates when the current folder changes
- View ▸ Show Finder After Archive Operations (off by default) sets
  Archive Utility's archive-reveal-after / dearchive-reveal-after, so
  expanding or creating an archive does not pop open a Finder window
- Devices menu and an All Mounts panel with per-volume unmount; at the root
  of an unmountable volume (external disk, disk image, network share) a
  floating ⏏ button unmounts it (the status bar confirms), and any window
  showing it moves to /Volumes. If files on it are open, a sheet lists them
  (and the apps using them) and the volume unmounts automatically once
  they are closed
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

## Keyboard shortcuts

| Action         | Shortcut           |
|----------------|--------------------|
| Copy           | ⌘C                 |
| Cut            | ⌘X                 |
| Paste          | ⌘V                 |
| New Window     | ⌘N                 |
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
