# Changelog

All notable changes to SketchyBar Studio will be documented here.

This project follows a human-readable changelog style and aims to use semantic versioning once tags begin.

## [Unreleased]

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
