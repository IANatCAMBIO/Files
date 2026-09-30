# files

A minimalist macOS file manager written in Objective-C + AppKit.

## Features

- List-view file browser with Name, Size, Kind, and Date Modified columns
- Sidebar with Favorites (Home, Desktop, Downloads, Documents, Applications) and Devices (mounted volumes)
- Full file operations: Cut, Copy, Paste, Move to Trash, New Folder, Rename
- Get Info panel with icon, size, permissions, owner/group, dates, and lock status
- Eject removable volumes from the sidebar
- FSEvents-based live directory watching
- Back/forward navigation with path control toolbar
- Inline search filter
- Context menu and standard keyboard shortcuts

## Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)

## Installation

```sh
make install
```

This builds the app bundle and copies it to `/Applications/files.app`.

## First run

```sh
make run
```

Or double-click `files.app` in Finder after installing.

## Keyboard shortcuts

| Action         | Shortcut           |
|----------------|--------------------|
| Copy           | ⌘C                 |
| Cut            | ⌘X                 |
| Paste          | ⌘V                 |
| Move to Trash  | ⌫ or ⌘⌫           |
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
