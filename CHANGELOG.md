# Changelog

All notable changes to SketchyBar Studio will be documented here.

This project follows a human-readable changelog style and aims to use semantic versioning once tags begin.

## [Unreleased]

### Added

- Quitting now asks what to do with unsaved edits: Save All, Discard, or Cancel. Closing the last window keeps the app alive while drafts exist.
- Files that disappeared from disk keep their session and draft. They are listed in a "Missing Files" section of the sidebar and the draft comes back when the file returns.
- The structured editor shows a file's read error, marks the sidebar row with a red dot, and disables the value editors and the save button for that file.

### Changed

- The code preview shows the pending draft instead of the file on disk, so the preview and the editor no longer disagree.
- Reloading the config and running `sketchybar --reload` no longer block the window. The reload happens in the background, and `sketchybar --reload` is stopped after 10 seconds instead of waiting forever on a permission prompt.

### Fixed

- Source editor edits can be saved again. The "Revert" and "Save Source" buttons, the toolbar save buttons, and the "Discard" button now enable as soon as the source draft changes.
- Editing a value no longer makes the app slow down: the preview, the sidebar and the bar preview only rebuild when their inputs change.

- Drafts are matched by a stable key (key path plus its ordinal occurrence) instead of by line number, so saving an unrelated file no longer discards another file's draft when a line above it moved.
- An edited value that no longer exists in the file is kept as a draft and reported instead of being dropped.
- `selectedFileID` cleared by the sidebar no longer shows a different file in the detail pane.
- The activation message is no longer overwritten by the reload that follows it.
- Saving one file now applies every staged loader order, not only the one of the selected file.
- A config folder that is a symlink to a folder already in the library is no longer added a second time.
- Adding a config folder that does not exist is reported instead of creating a broken library entry.
- The last used config folder is restored on launch.
- Editing a value that no longer exists reports it instead of dropping the keystroke.

- Editing a symlinked config file keeps the symlink: the write lands on the real file instead of replacing the link with a regular file.
- Backups of symlinked files are regular files with the original content, and a failed copy keeps the previous backup instead of emptying the slot.
- The backup mirror moved to `backups/.sketchybar-studio/`, so it never overwrites a file kept in `backups/` by the user.
- Switching to a config nested inside the symlinked live config folder is refused instead of pointing the live folder at a subtree with no entrypoint.
- A bare `require("name")` only matches a file in the config root, not a same-named file in a subfolder.
- Toggling an item comments every loader line that loads it, across all entrypoints.
- Restores and config switches keep the displaced copy under Application Support instead of next to the config folder.
- An install interrupted by a crash is repaired on the next launch instead of leaving the live path missing.
- Saves and loader edits re-read the file right before writing, so an external edit is reported instead of overwritten.
- A corrupt config library file is reported and left untouched instead of being replaced by the default config.
- Hex colors such as `0xff000000` are no longer truncated to `0` when scanned.
- Colors are now detected from the key and from unquoted hex literals, so a quoted label like `"#ff0000"` is no longer edited as a color.
- `updates` is edited as SketchyBar's `on`/`off`/`when_shown` enum and is written as a quoted string.
- Shell values are always written quoted and escaped, and invalid numbers, colors and booleans keep their original text.
- Shell array assignments, trailing comments and heredoc bodies are no longer reported as editable values.
- Lua comments and long strings no longer produce phantom editable values.
- Colors are read as SketchyBar's AARRGGBB word, so `0xAARRGGBB` and `#AARRGGBB` agree.
- The boolean key list now matches SketchyBar and includes `clip`, `lazy`, `cache_scripts` and `show_in_fullscreen`.

## [1.0.1] - 2026-07-22

### Added

- Added SwiftPM regression tests for backup mirroring and activation matching.
- CI now runs `swift test` in addition to build and package checks.

### Changed

- Optimized activation lookup so config reload reads loader files once per reload instead of once per editable file.
- Config discovery now skips the `backups/` subtree before descending into it.
- Lua and shell scanners reuse compiled regexes instead of recompiling on every file scan.

### Fixed

- `Save & Apply` no longer reloads SketchyBar after a failed save.
- Activation matching now prefers the longest matching token, avoiding collisions such as `space.lua` versus `spaces.lua`.

## [1.0.0] - 2026-07-03

### Added

- Config Library for managing multiple SketchyBar config folders.
- Per-config profile storage, so each config has its own snapshot set.
- Settings UI for adding, selecting, and removing config folders.
- `Make Selected Live` action to point `~/.config/sketchybar` at selected config via symlink, with backup of existing live config when needed.
- Live config status indicator.
- Confirmation before switching the live config symlink.
- Confirmation before restoring a profile snapshot.
- `AGENTS.md` contributor guidance for future development work.
- Read-only code preview improvements with wrapping, system UI font, dynamic spacing, and lightweight Lua/sketchybarrc syntax highlighting.
- Theme-aware syntax colors for the code preview.

### Changed

- Profiles now belong to selected config instead of one global profile pool.
- Settings window now uses topic-based tabs for a cleaner configuration flow.
- Item editor values are grouped into practical sections such as item, icon, label, background, popup, and scripts.
- Sidebar organization now better follows SketchyBar config folders and groups items by left, center, right, or unpositioned bar placement.
- Loader-backed items can be reordered from the sidebar by updating their entrypoint order.
- README now includes project inspiration links for SketchyBar and SbarLua.

## [0.1.0] - 2026-05-05

### Added

- Native SwiftUI macOS app scaffold.
- Lua config discovery and scalar assignment editing.
- Old-school `sketchybarrc`, `.sketchybarrc`, and shell script discovery.
- Path-first sidebar grouping with nested folders.
- Activation toggles that comment/uncomment loader lines.
- SketchyBar-aware value dropdowns.
- Native color picker with opacity, saved as `0xAARRGGBB`.
- Native macOS font panel, saved to SketchyBar font syntax.
- Read-only code preview pane.
- Profile snapshots for saving/restoring full config folders.
- Search, changed-only filter, Save All, Save & Apply, and `sketchybar --reload`.
- Programming-inspired app themes: Nord, Dracula, Monokai, Tokyo Night, Catppuccin.
- GitHub project docs, CI workflow, and issue templates.

### Changed

- Boolean-style options normalize to `true` / `false`.
- `updates` uses `on`, `off`, and `when_shown` instead of boolean normalization.
- Activation matching avoids core config files like `bar.lua`.

### Known Limits

- Lua parsing intentionally edits simple scalar assignments first.
- Shell parsing focuses on common `key=value` SketchyBar property syntax.
- Exotic loader patterns may need additional activation matching rules.
