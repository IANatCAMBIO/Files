# Files — User Guide

The full reference for Files. See [README.md](README.md) to install it and
[BUILD.md](BUILD.md) to build it.

- [Browsing and views](#browsing-and-views)
- [Bookmarks bar](#bookmarks-bar)
- [Get Info and the info sidebar](#get-info-and-the-info-sidebar)
- [Git working trees](#git-working-trees)
- [Copying and moving](#copying-and-moving)
- [Creating, renaming and deleting](#creating-renaming-and-deleting)
- [Disk images and archives](#disk-images-and-archives)
- [Search](#search)
- [Folder sizes](#folder-sizes)
- [Mounts and volumes](#mounts-and-volumes)
- [Default apps](#default-apps)
- [Preferences](#preferences)
- [Replacing Finder](#replacing-finder)
- [Keeping Files running](#keeping-files-running)
- [Keyboard shortcuts](#keyboard-shortcuts)

## Browsing and views

- List-view browser with Name, Size, Kind, Permissions, Date Modified and
  Date Created (hidden by default) columns; click a header to sort
  (Finder-style name order), right-click the headers to show or hide
  columns (every list follows). The Permissions and Comment headers do not
  sort, as neither holds a value a list can be put in order by.
- Default sort (Preferences ▸ View): the column every new window and
  folder starts sorted by — Name, Size, Kind, Date Modified or Date
  Created — and its direction, worded for the column ("Newest first",
  "Largest first", "Z → A"). Date Modified, newest first, out of the box.
  Changing it re-sorts the windows already open; clicking a column header
  re-sorts that window alone and leaves the setting as it is.
- View ▸ Always Show Folders First (on by default; also in Preferences)
  keeps every folder above the files, as Finder does. Turn it off and
  folders take their place among the files in whatever order is in force.
- Auto-fit columns (View ▸ Auto-Fit Columns, on by default) sizes every
  column but Name to the widest thing in it, and gives Name all the width
  that is left: the other columns hold values of a predictable width, so
  Name is the one that takes the window, growing and shrinking with it.
  Turn it off to size the columns by dragging their headers instead.
- Optional double-height rows with larger icons (View ▸ Large Rows).
- Sizes read as KB, MB and GB (View ▸ Human Readable File Sizes, on by
  default), counted in thousands as Finder counts them. Turn it off and
  the Size column shows the exact number of bytes, which is what you want
  when comparing two files that round to the same figure.
- Single- or dual-pane browsing (View ▸ Dual Pane, ⇧⌘2; Tab switches
  panes; right-click a folder ▸ Open in Split Pane).
- The status bar shows the item count and, on the right, the free and
  total space of the disk being browsed ("10.3 GB (of 245 GB) free"; free
  space counts purgeable space, as Finder does). View ▸ Show Used Disk
  Space (off by default; also in Preferences) shows the space used instead
  ("234.8 GB (of 245 GB) used"). A spinner at its left shows while a slow
  folder (e.g. a File Provider mount) is still loading.
- View ▸ Show Full Path in Title (on by default; also in Preferences)
  titles the window with the active pane's full path instead of just the
  folder name.
- Type-select: with the list focused, typing a letter jumps the selection
  to the next item whose name starts with it, as in Finder; keep typing to
  narrow it (the typed letters are forgotten after about a second). Only
  names are matched, never a row's kind, permissions or comment.
- Quick Look: Space previews the selection (Space or Esc closes it; the
  arrow keys move through the list and the preview follows).
- Address bar in the toolbar (accepts `~` and relative paths), with the
  bookmark star beside it, between Reload and the hidden-files eye. It
  stretches to every point the other toolbar items can spare and gives
  them back as the window narrows; the buttons and the search field stay
  packed against the right edge of the toolbar, and when the window gets
  narrow enough that the search field shuts to its magnifying glass, the
  address bar takes the room it gives up. The toolbar has no Back and
  Forward buttons: the address bar takes the room they would want, and
  Go ▸ Back (⌘[) and Go ▸ Forward (⌘]) navigate without them. Up, Open in
  Terminal, show/hide hidden files (View ▸ Show Hidden Files, ⇧⌘., or the
  toolbar's eye button — macOS flags `/Volumes`, `/usr`, `/private` and
  the other Unix directories hidden, so `/` lists only four items until
  this is on). An ⏏ toolbar button opens All Mounts, and appears only
  while something unmountable is mounted.
- Live updates when the current folder changes; a folder that cannot be
  read (no permission, a disconnected server) says so in the status bar.
  Folders are listed in the background, so a slow or unresponsive network
  folder never freezes the window.
- Symbolic links are followed (a link to a folder opens that folder).
- App bundles open like folders; right-click ▸ Run Application launches one.

### How a folder is read

Everything a row shows — name, size, dates, permissions, kind, whether
the item is a folder, a package, an application, a symbolic link, hidden,
or carries an icon of its own — is read once, with the listing, on a
background queue. Rows never touch the volume as they are drawn, which is
why an unresponsive network share or File Provider mount cannot freeze
the window.

The read itself is one `getattrlistbulk` call per few hundred items,
which returns the names and all those attributes together, rather than
Foundation's resource values, which cost a read per item. Measured on a
folder of 10,000 items: 34 ms against 425 ms for the attributes, and 44
ms against 469 ms including the icons. An ordinary folder of a few
hundred items goes from around 14 ms to under 2 ms. The kind strings the
Kind column shows ("Folder", "Application", "Rich Text Document") still
come from Launch Services, but once for each kind of item in the folder
instead of once per item.

"Each kind of item" means each filename extension, because that is what
decides the type. A file with no extension at all is the exception:
Launch Services looks past the name for those, so a `Makefile`, a
`LICENSE` and a binary with no extension are three different kinds that
share an empty one, and each has to be asked about separately. Its own
type is resolved per file; everything that follows from the type — the
kind string, whether it is a package or an application — is still shared.
A folder of extensionless files is therefore dearer than a folder of
photographs: `/usr/bin`, 924 items of which 817 have no extension, reads
in about 29 ms, against about 38 ms for 10,000 items that do.

Two sorts of folder are read a second time, by path, because the batched
call describes the wrong directory for them: a firmlink and a mount
point. Both live at the root of a volume — `/Library`, `/Users`,
`/Applications` and `/dev` among them — and without the second read every
one of them showed the volume root's own date instead of its own.

A volume whose file system does not offer batched attributes — some
network and FUSE mounts — is read item by item instead, which is slower
but gives exactly the same rows. If that per-item read is unsupported
too, the folder reports that it cannot be read rather than appearing
empty.

## Bookmarks bar

Directly under the toolbar, where Tasks and Notes put their Favorites bar
(Home, Desktop, Downloads, Documents, Applications, Trash). ⌘D adds the
current folder, and right-click ▸ Add to Bookmarks on a folder in the list
adds that folder (before Trash, which is always last). The star right of
the address bar, in the toolbar, shows ★ when the current folder is a
bookmark and ☆ when it is not; click it to toggle. Drag a bookmark along
the bar to reorder it, and right-click it to remove it. When the window is
too narrow for every bookmark, scroll over the bar (mouse wheel or
trackpad) to move along it. View ▸ Show Bookmarks Bar or the same checkbox
in Preferences ▸ View (on by default) hides or shows it in every window.

The Trash bookmark shows a full can when there is anything in the Trash
and an empty one when there is not. It follows an app-wide watcher on the
Trash folders, so it changes within about half a second of anything being
trashed or emptied — by Files, by Finder or by any other app — without a
window having to list the Trash. Items whose name begins with a dot do
not count as contents, as in Finder. (The Empty Trash button that appears
while the Trash is on screen always shows an empty can: it pictures what
the button does, not what the Trash holds.)

The Go menu lists Home, Desktop, Downloads, Documents and Trash, then a
Bookmarks section listing every bookmark in bar order.

## Get Info and the info sidebar

- Collapsible info sidebar with a Quick Look thumbnail and file details.
- Get Info panel (⌘I): kind, the app that opens the file, size, dates,
  owner/group, editable permissions, Locked flag, rename, and SHA-256 /
  MD5 checksums (Preferences ▸ Show Hashes in Get Info, off by default).
- **change** — the link after the Opens with: value opens
  [Set Default Apps](#default-apps) with this file's type found and
  selected, ready to point it at another application. It is not shown for
  the items that open themselves (folders and application bundles), which
  have no default application to change. A file macOS recognises no type
  for is `public.data`, which has no extension of its own; its row is
  added to the list when the link is followed, with `—` for its
  extensions. Remember that what the link leads to is a system-wide
  setting for every file of that type, not a setting for this one file.

### Giving an item its own icon

The icon at the top of the Get Info panel is a drop target, as it is in
Finder: drag an image file, an `.icns` file, or an image out of another
application (Preview, a browser, Photos) onto it and it becomes that
item's icon. The well draws an accent ring while it is ready for the drop,
and refuses a drag it cannot use — anything that is not an image, a locked
item, and an item you have no permission to write. An `.icns` is read from
disk rather than off the pasteboard, so the icon keeps every size it holds
and still looks right at 16 points.

A **revert** link appears under the icon while the item has an icon of its
own; it removes it, and the item's type icon shows again.

macOS stores the icon on the item itself: in the resource fork of a file,
and in a hidden `Icon\r` file inside a folder, with the `kHasCustomIcon`
flag set in `com.apple.FinderInfo` either way. So the icon travels with a
copy, Finder and the Dock show the same one, and both extended attributes
appear in the panel's Extended Attributes list. Writing it changes the
item's modification date, and the panel re-reads the item afterwards to
show that.

File-list rows show it too, as Finder does. The list still gives every
file of a type the same cached icon — one image for a folder of ten
thousand JPEGs — and reads an item's own icon only where it carries one.
Which files those are arrives free with the listing (see [How a folder is
read](#how-a-folder-is-read)), and nothing is read when rows are drawn,
so a slow volume still cannot freeze the window.

## Git working trees

The top folder of a git working tree shows its usual folder icon with a
git badge centered on it. Inside a repository the list gains a Git column
that reads "tracked" for every file git tracks (including newly added
ones) and every folder containing one, and is blank for untracked and
ignored items; it updates when the index changes (add, rm, commit,
checkout) and is filled in just after the list appears, so large
repositories never hold up a folder.

The repository's Get Info panel adds a Git section: the current branch,
whether it is pushed (compared with its upstream as of the last fetch —
commits ahead/behind, no upstream, detached HEAD), and the remote URL (the
upstream's remote, else origin). The info sidebar shows the same three as
Branch, Pushed and Remote rows.

Git features need Xcode or the Command Line Tools and are off without them.

## Copying and moving

Copy, cut and paste, and drag and drop (moves by default; hold ⌥ to copy),
with a progress panel (status line, progress bars, transfer log, cancel),
Keep Both / Replace prompts, and optional SHA-256 verification (View ▸
Validate Copies with SHA-256, also in Preferences ▸ Move/Copy). View ▸
Simple Copies (off by default; also in Preferences ▸ Move/Copy) skips the
panel: transfers run silently, keeping both on name clashes, and only
errors are shown.

Copies use APFS clones when possible and keep extended attributes, tags,
ACLs, the Locked flag and dates; nothing at the destination is replaced
until the new copy is complete. With validation on, each file's source is
hashed before it is copied and its staged copy straight after, and the
copy stops at the first mismatch; APFS clones are hashed like any other
copy. Files kept only in iCloud are downloaded first, with their progress
shown in the panel ("Downloading … from iCloud"); moves within iCloud
Drive need no download.

### Why the progress panel counts steps, not bytes

The progress panel counts a job in **steps**, because byte totals say
little about how much of a transfer is left: hashing a file costs about as
much as copying it, and a same-volume move or an APFS clone moves no data
at all.

Every file costs five steps with validation on — hash the source, copy it
into a staging file, hash the staged copy, compare the two, then rename
the staged file into place or delete it — and two without: copy it into a
staging file, then rename it into place. A move that stays on one volume
is a single rename however many files it covers.

The job's steps are counted before anything moves, so there is a progress
bar for the file being transferred and, when the job covers more than one
file, a second one for the job as a whole. The bar that stands for the job
is followed by "52% @ 5.7 MB/s": the rate is every byte of every file
copied over the time since the job started, so hashing, which moves no
bytes but does take time, pulls a validated copy's average well under the
volume's own speed, and a same-volume move shows no rate at all because it
copies nothing.

The status line above them is the newest line of the transfer log, so the
two always agree: the log opens with the job, names each step as it
begins, reports each file's success with the SHA-256 both sides agreed on,
and closes with the job's result, error count and elapsed time.

## Creating, renaming and deleting

Move to Trash, Empty Trash, New Folder and New File (File menu or the
toolbar's + button), Paste Into (right-click a folder while files are on
the clipboard), inline rename (right-click ▸ Rename, and straight after
New Folder / New File; the name without its extension is selected, ready
to type). Return opens the selection, like a double-click: folders in the
list, files in their default app.

## Disk images and archives

- Opening a disk image (.dmg, .iso, …) mounts it and opens its volume in a
  new window; password-protected or licensed images are handed to the
  system's DiskImageMounter to ask, then open the same way.
- Opening an archive (.zip, .tar, .tar.gz, .tgz) hands it to whichever app
  macOS has for it — Archive Utility unless you have changed it — exactly
  as Files hands over any other file it does not display itself. Expanding
  is that app's job, including its progress, its password prompt for an
  encrypted zip and its own handling of a damaged one; Files does not
  unpack archives itself.
- Right-click ▸ Create Archive… on one or more items in the same folder
  asks for the format (zip, tar.gz or tar), the file name and, for zip, an
  optional password; the archive is made in that folder and selected.
  Passwords go to `zip` through a terminal, never on a command line where
  `ps` would show them. Zip password protection is the older
  ZipCrypto scheme, which is weak; tar cannot be password protected.
- While Files is the default file browser, expanding or creating an
  archive does not pop open a Finder window — which is what keeps the
  handoff above feeling in place rather than bouncing you to Finder:
  Archive Utility's
  archive-reveal-after / dearchive-reveal-after are off (checked at every
  launch, including the first) and come back on with Set default file
  browser to Finder.

## Search

Spotlight search by name (⌘F), in the current folder and its subfolders or
across the whole Mac (the search field's magnifying-glass menu: This
Folder / This Mac; the empty field shows which). The first 5,000 matches
are shown, and the status bar says when there are more.

## Folder sizes

View ▸ Show Folder Sizes (off by default; also in Preferences): the Size
column shows each folder's total — every file inside it, at any depth,
added up (symbolic links not followed, other volumes not entered). Totals
are counted in the background, one folder at a time, and fill in as they
finish ("…" until then); sorting by Size uses them. They are kept while
you stay in the folder; Reload counts them again.

## Mounts and volumes

The Mounts menu lists the mounted volumes under a Mounted Filesystems
heading, then, under a Fileproviderd heading, the cloud storage (iCloud
Drive and File Provider accounts such as Google Drive).

An All Mounts window (Mounts ▸ All Mounts…, or the toolbar's ⏏ button,
which is there only while a volume is mounted that can be unmounted) gives
per-volume unmount. At the root of an unmountable volume (external disk,
disk image, network share) a floating ⏏ button unmounts it (the status bar
confirms), and any window showing it moves to /Volumes. If files on it are
open, a sheet lists them (and the apps using them) and the volume unmounts
automatically once they are closed.

## Default apps

Files ▸ Set Default Apps… lists every file type this Mac knows about, with
its icon, the extensions it covers, its kind, the application macOS opens
it with, and the type's identifier. Click a column header to sort by it;
the search field under the list narrows it by extension, kind, application
name or identifier (typing `.md`, `markdown`, `Preview` or `public.jpeg`
all find their rows). Anything too wide for its column is in the cell's
tooltip.

The window also opens here from Get Info: the **change** link after a
file's Opens with: value opens it with that file's type already selected.

**Double-click a row** — or select it and press Return, or click Change… —
to choose the application that opens that type. The chooser offers the
applications that say they can open it, with the current default selected,
and Other App… picks any application on the Mac, for a type nothing claims
or an editor that never registered for it.

### One row per type, not per extension

macOS records the default application against a **content type** (a
uniform type identifier such as `public.jpeg`), not against an extension,
and one type usually covers several extensions: `public.jpeg` is `.jpeg`,
`.jpg` and `.jpe`, and `net.daringfireball.markdown` is `.markdown`,
`.markd`, `.mdown` and `.md`. So the list holds one row per type, showing
every extension it covers, and changing a row changes what opens all of
them. That is what "all files of that extension" can actually mean here;
a list of one row per extension would promise `.jpg` and `.jpeg` could
differ, and they cannot.

The rows are worked out by reading what the applications installed on this
Mac and macOS itself declare they open, then resolving each extension back
to the type a file carrying it really gets — as a plain file and as a
package, since `.rtfd` and `.workflow` only ever exist as packages. A type
nothing resolves to is left out, so two applications both declaring a type
for `.ada` give one row, not two rows of which only one would do anything.

An extension no declaration names at all still gets a row, under the
dynamic type macOS makes for it (an identifier starting `dyn.`, with `—`
for its kind, since such a type has no name of its own). `.bashrc`,
`.mermaid` and `.asm` are usually among them, and a default application
set on one works like any other.

### What macOS does and does not allow

Changing a default is a system-wide setting — the same one Finder's
"Open with ▸ Change All…" sets. It outlives Files and applies to every app
that opens a document, and it is not undone by uninstalling Files.

- **macOS asks first.** Confirming a change puts up a system dialog of its
  own, presented by CoreServicesUIAgent (so it carries a system icon, not
  Files'). Declining it leaves the default alone and Files says nothing —
  saying no is an answer, not an error.
- **macOS sometimes refuses.** It will not register an application it does
  not index — one inside a cache folder, a disk image, or a folder outside
  the usual application locations — and it keeps a few of its own types for
  itself. LaunchServices reports no error when it does this, so Files
  checks afterwards what the type now opens with and says plainly that the
  change did not take, rather than leaving a list that quietly did not
  change. Moving the application to `/Applications` is usually the fix.

The list is re-read every time the window opens and after every change, so
it shows the defaults as they are now even if Finder or another app
changed one.

## Preferences

Files ▸ Preferences…, ⌘,

| Tab | Settings |
|---|---|
| View | Default sort order and direction, and the View-menu preferences (folders first, bookmarks bar, auto-fit columns, large rows, folder sizes, human readable file sizes, used disk space, full path in title), plus Show Hashes in Get Info |
| Move/Copy | Simple Copies; Validate Copies with SHA-256 |
| Integration | Default file browser (Set Files as default / Set Finder as default — each opens a change log, and the ⓘ beside the heading lists what follows the default); Keep Files running for faster startup |

Default applications per file type are not in Preferences: they are a
system-wide setting with a window of their own (see
[Default apps](#default-apps)).

About Files shows the version (from the `VERSION` file), build date, the
app's motto, and links to camb.io and the license.

## Replacing Finder

On first launch Files makes itself the default file viewer. It does not
replace or disable Finder, which macOS still needs. Instead it changes these
settings:

| Setting | Files sets | Effect |
|---------|------------|--------|
| `NSGlobalDomain NSFileViewer` | `com.cambio.files` | "Show in Finder" / "Reveal in Finder" in other apps (browser downloads, editors, System Settings' reveal buttons, `open -R`) opens Files, with the item selected in its folder |
| `com.apple.finder CreateDesktop` | `false` | Finder draws no desktop icons |
| `com.apple.finder QuitMenuItem` | `true` | Finder ▸ Quit Finder exists |
| `~/.zshrc` block between `# BEGIN Files: open folders in Files` and `# END Files: …` | an `open` shell function | `open <folder>` in Terminal opens Files. Anything else (files, options, `.app` and other packages) goes to the real `open`, as does a folder if Files can't be opened. Added only if zsh is your login shell, takes effect in new Terminal windows, and is removed when Finder is made the default again |
| `com.apple.archiveutility dearchive-reveal-after`, `archive-reveal-after` | `false` | Archive Utility opens no Finder window on what it expands or creates (needs Full Disk Access; set back to `true`, Archive Utility's default, when Finder is made the default again) |

Files quits Finder when it changes Finder's settings. Finder only reads
them at launch. It stays quit until something asks for it (its Dock icon,
the Dock's Trash, AirDrop, and so on), and then runs without desktop icons.

Files records each setting's original value (or that it was not set)
before changing it. Every launch re-checks the settings and puts back any
that something else reset.

Files can't become the default app for folders. The LaunchServices API
refuses (`LSSetDefaultRoleHandlerForContentType` returns `paramErr` for
`public.folder`). macOS 26 also ignores a `public.folder` entry written
straight into the `com.apple.launchservices.secure` preferences (the way
ForkLift documents), even after logging out and back in, and later drops
it. So Files doesn't write one.

This is a different request from a reveal. Revealing an item ("Show in
Finder", System Settings' reveal buttons) goes to the app named in
`NSFileViewer`, which is Files. Opening a folder (a Dock folder's "Open in
Finder", Return on a Spotlight folder result, an app opening a folder
rather than revealing it) goes to the default app for folders, which
stays Finder. In zsh, the `open` function sends `open <folder>` to Files.

A revealed file is selected in its folder: the list scrolls to it and takes
keyboard focus, so ↑ and ↓ carry on from there. Several items revealed
together are all selected, and items in different folders open a window
each. A revealed folder opens to show its contents instead: macOS sends
reveals as plain "open" requests, so Files can't tell them apart. Hidden
items are only selected while hidden files are shown.

Some things still go to Finder, because macOS gives other apps no way to
take them:
- a folder another app opens rather than reveals: a Dock folder's "Open
  in Finder", a Spotlight folder result (the default app for folders)
- double-clicking a folder inside a Finder window
- the Finder and Trash icons in the Dock
- AirDrop and Connect to Server
- AppleScripts that name Finder

### The change log

**Set Files as default** and **Set Finder as default** each open a change
log (in Console, from
`~/Library/Logs/Files/default-file-browser-<date>.log`) listing every
setting it checked or changed: its value before and after, the Terminal
command that makes the same change (`defaults write …`, or `cat >>` /
`sed` for the `~/.zshrc` function), and whether the new value was
confirmed by reading it back. The summary at the end lists each check with
the `defaults read` command that shows it. Clicking the button for the
current choice re-checks and repairs every setting.

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
it on from `~/Applications/Files.app`, not from a build in the project
folder.

## Keyboard shortcuts

| Action         | Shortcut           |
|----------------|--------------------|
| Copy           | ⌘C                 |
| Cut            | ⌘X                 |
| Paste          | ⌘V                 |
| New Window     | ⌘N                 |
| Preferences    | ⌘,                 |
| Open the chooser for the selected file type | Return (Set Default Apps window) |
| Find (search)  | ⌘F                 |
| New File       | ⌥⌘N                |
| Move to Trash  | ⌘⌫                 |
| Add Bookmark   | ⌘D                 |
| Open in Terminal | ⌘⇧T              |
| Dual Pane      | ⌘⇧2                |
| Show Hidden Files | ⌘⇧.             |
| New Folder     | ⌘⇧N                |
| Get Info       | ⌘I                 |
| Select All     | ⌘A                 |
| Open           | Return             |
| Back           | ⌘[ or ←            |
| Forward        | ⌘] or →            |
| Home           | ⌘⇧H                |
| Desktop        | ⌘⇧D                |
| Downloads      | ⌘⇧L                |
| Documents      | ⌘⇧O                |
| Jump to an item | type its first letters |
