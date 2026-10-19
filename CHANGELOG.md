# Changelog

All notable changes to SketchyBar Studio will be documented here.

This project follows a human-readable changelog style and aims to use semantic versioning once tags begin.

## [Unreleased]

### Added

- SbarLua item tables are now read with their real structure. A value inside a nested table keeps its full path, such as `icon.font.size` or `background.border_color`, instead of a flat `size` or `border_color` that could belong to any part of the item. The values are grouped by the part of the item they belong to, and the option reference shows the entry of the exact key.
- Most SketchyBar options now have a reference entry: an info button next to the key path opens a popover with the meaning, the type, the accepted values and the default of the option. The summary is also part of the tooltip of the value editor.
- The dropdown suggestions come from the SketchyBar property table instead of a short hand written list, so options such as `symbol_mode`, `anchor` and `cap` now offer their real values.
- Quitting now asks what to do with unsaved edits: Save All, Discard, or Cancel. Closing the last window keeps the app alive while drafts exist.
- Files that disappeared from disk keep their session and draft. They are listed in a "Missing Files" section of the sidebar and the draft comes back when the file returns.
- The structured editor shows a file's read error, marks the sidebar row with a red dot, and disables the value editors and the save button for that file.
- A reachability map shows what SketchyBar really loads. The new toolbar button opens a sheet with the files no loader reaches, the loader lines that point at files that are gone, and the require cycles. The map only reads the config and never changes it.
- A config validator finds the problems SketchyBar ignores. The new "Diagnostics" toolbar button opens a sheet with the unknown options of an item, the values SketchyBar cannot use, the aliases that are used twice, the loader lines that point at a file that is gone, the files no loader reaches, the files with unbalanced brackets, and the item files that declare nothing. Every finding names the file and the line, and clicking it reveals the file in Finder. The validator only reads the config and never changes it.
- The bar preview draws the real item: an SF Symbol, the icon of an installed app, a media artwork or the text of the icon, the real label, and the font, the text color and the background color of the config. An SF Symbol that SketchyBar would reject is shown with a warning, and an app that is not installed is shown with a placeholder.

### Changed

- The code preview shows the pending draft instead of the file on disk, so the preview and the editor no longer disagree.
- Reloading the config and running `sketchybar --reload` no longer block the window. The reload happens in the background, and `sketchybar --reload` is stopped after 10 seconds instead of waiting forever on a permission prompt.
- The sidebar lists the categories in the documented order: items, widgets, bar, themes, scripts.
- The source editor shows line numbers next to the text.
- The Settings window uses the same dark scheme as the main window, and the folder picker opens as a sheet.
- A shell value keeps the quoting it has in the file. A double quoted value keeps its `$` and backtick live, a single quoted value stays single quoted and literal, and an unquoted value stays unquoted when it is a safe word.
- The shell scanner only offers values that are SketchyBar options. Function locals such as `local result=5` and loop counters are no longer listed as editable options, while `export FOO=bar` still is.
- A `sketchybarrc` that holds Lua code is read as Lua. Its `require(...)` lines are loader references, so the files they load can be switched off and ordered.

### Fixed

- Values that are built by an expression, such as `position = "popup." .. name` or `color = colors.red`, are no longer offered as editable values. Only the leading literal of such a value was found before, so editing it wrote back a part of the expression and broke the item.
- Toggling or reordering a loader reference no longer deletes the byte-order mark of the file.
- Restoring a profile keeps the `backups/` folder of the config root, so the backup mirror of a dotfiles repository survives the restore.
- Number fields only accept numbers. Text that is not a number is marked with a warning and never reaches the file.
- The color picker keeps the format of the value it replaces, so `#ff8800` stays `#ff8800` instead of turning into `0xffff8800`. A color that cannot be read is reported next to the field.
- The font panel no longer writes a half typed font family, so a name that does not exist cannot reach the file.
- The staged loader order is visible in the sidebar, and a staged row shows its new position until the file is saved.
- Dropping an item on a bar column moves it, also when the item is not active yet. The position and the loader order change together, so a refused move changes nothing.
- Reordering items that are loaded by different entrypoints is refused with a message instead of failing silently.
- Clicking a value row no longer takes the focus away from the text fields.
- The code preview scrolls to the selected line.
- The width picker uses the width that is already in the file and never writes a width of 0, which would hide the item.
- Icon-only buttons and switches have accessibility labels, the status message is styled by kind and read out by VoiceOver, and the settings keep the path that was typed.
- Source editor edits can be saved again. The "Revert" and "Save Source" buttons, the toolbar save buttons, and the "Discard" button now enable as soon as the source draft changes.
- Editing a value no longer makes the app slow down: the preview, the sidebar and the bar preview only rebuild when their inputs change.

- Drafts are matched by a stable key (key path plus its ordinal occurrence) instead of by line number, so saving an unrelated file no longer discards another file's draft when a line above it moved.
- A draft now stays on the value it was made on. A draft is only carried over to a value that still holds the text the draft was made from, so a new block with the same option no longer moves an edit to another item. A draft that cannot be matched safely is reported and kept instead of being written to another value.
- An edited value that no longer exists in the file is kept as a draft and reported instead of being dropped.
- "Save All" now also covers the files that are missing from disk. The status message names every file whose draft could not be saved, the draft stays in memory, and the app keeps running until the draft is saved or discarded.
- The backup under `backups/.sketchybar-studio/` holds the exact text that is about to be overwritten, not a version another process wrote in the meantime.
- A file that is missing from disk stays marked as missing after an edit, so it keeps its place in the "Missing Files" section of the sidebar.
- A `<<` that is not a heredoc, such as `count=$((a<<b))`, no longer hides the rest of a shell file. A heredoc whose terminator is missing no longer hides the rest of the file either.
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
- The boolean key list now matches SketchyBar: it has `show_in_fullscreen`, `highlight` and `font_typographical_width`, and no longer has `clip`, `lazy` or `cache_scripts`.
- The option reference is checked against the SketchyBar sources. The entries for `id`, `properties`, `mouse`, `content_update`, `content_replace` and the `stack` keys are gone, because SketchyBar has no such properties and answers with `Invalid property`. The entries for `cache_scripts` and `lazy` are gone for the same reason.
- The color parts `alpha`, `red`, `green` and `blue` now use the range 0 to 1, which is what SketchyBar clamps them to. The example of `hex` needs the `0x` prefix, because SketchyBar reads the value as a number.
- `scroll_duration` is a number of frames at 60 frames per second, not a number of milliseconds, and the height of a popup follows the height of the bar window.
- The reference tells the item level and the bar level apart. The `display` of an item no longer offers `all` and `main`, which SketchyBar reads as a broken display mask, and the `bar.` entries hold the defaults of the bar.
- The reference popover shows the key path of the value, such as `icon.font.size`, and not only the name of the leaf.
- Clicking the info button of a value no longer selects the value row.
- A dropdown of a value that is not in the file no longer shows nothing, because the empty value is now an entry of the list.

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
