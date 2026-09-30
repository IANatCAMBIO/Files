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
- Git folders: the top folder of a git working tree shows a GitHub folder
  icon (light or dark to match the system appearance), and its Get Info
  panel adds "Git folder detected", the current branch, and whether the
  branch is pushed (compared with its upstream as of the last fetch —
  commits ahead/behind, no upstream, detached HEAD)
- Copy, cut and paste, and drag and drop (moves by default; hold ⌥ to
  copy), with a progress panel (speed graph, transfer log, cancel), Keep
  Both / Replace prompts, and optional SHA-256 verification (View ▸
  Validate Copies with SHA-256). View ▸ Simple Copies (on by default) skips
  the panel: transfers run silently, keeping both on name clashes, and only
  errors are shown; turn it off to get the full progress panel. Copies use APFS clones
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
- View ▸ Show Finder After Archive Operations (off by default) keeps
  Archive Utility's archive-reveal-after / dearchive-reveal-after in step
  with the menu (checked at every launch, including the first), so by
  default expanding or creating an archive does not pop open a Finder window
- Devices menu and an All Mounts panel with per-volume unmount; at the root
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
