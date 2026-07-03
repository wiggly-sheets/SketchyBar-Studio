# AGENTS.md

Guide for future agents working on SketchyBar Studio.

## Project

SketchyBar Studio is a native macOS SwiftUI companion app for editing existing SketchyBar configs. It should make config editing safer and more discoverable without taking ownership away from the user's files.

Core goals:

- Edit existing Lua, `sketchybarrc`, and shell-based SketchyBar configs.
- Preserve user config structure and comments whenever possible.
- Prefer native macOS controls: `NSOpenPanel`, `ColorPicker`, font panel, SwiftUI settings/forms/split views.
- Keep all theming inside this app only. Do not use system-wide theming, app injection, SIP-disabling tools, or anything that changes Notes, Safari, Finder, or other macOS apps.
- Treat SketchyBar and SbarLua syntax as the source of truth for option names and valid values.

## Repo Layout

- `Package.swift` - SwiftPM package for the macOS app.
- `Sources/SketchyBarStudio/App` - app entry point.
- `Sources/SketchyBarStudio/Models` - config/profile/theme data models.
- `Sources/SketchyBarStudio/Services` - file discovery, parsing, config switching, activation toggles, profile archive logic.
- `Sources/SketchyBarStudio/Stores/SketchyBarStore.swift` - main observable app state and actions.
- `Sources/SketchyBarStudio/Views` - SwiftUI UI.
- `Sources/SketchyBarStudio/Support` - focused platform/value helpers.
- `Assets` - app icon/logo assets.
- `script/build_and_run.sh` - build, bundle, run, package, and universal package helper.
- `dist` - generated app bundle output. Do not hand-edit generated bundles.

## Build Commands

Use these from repo root:

```bash
swift build
./script/build_and_run.sh --package
./script/build_and_run.sh --universal-package
```

For release sanity:

```bash
lipo -info dist/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
```

The package is unsigned unless signing is added later. README documents Gatekeeper quarantine removal for trusted preview builds.

## Coding Rules

- Match existing SwiftUI style before adding new abstractions.
- Keep edits scoped. Avoid broad refactors unless they unblock the requested feature.
- Prefer typed helpers over string hacking when adding parsing or value normalization.
- Use `FileManager`, `URL`, and line-based rewrites carefully; preserve newlines and indentation.
- Never run destructive git commands or delete user config files.
- When editing user SketchyBar configs, keep `.studio-backup` behavior intact.
- Use native macOS affordances before custom UI.
- Avoid adding external Swift package dependencies unless the benefit is clear and CI/release impact is handled.

## SketchyBar Config Safety

Config roots may be real folders or symlinks, commonly `~/.config/sketchybar` pointing into a dotfiles repo. Follow symlinks naturally via `URL`/`FileManager`, and never replace a real config without a backup.

Activation toggles work by commenting or uncommenting loader references in `init.lua`, `sketchybarrc`, `.sketchybarrc`, or shell loader files. Core files such as `bar.lua`, theme files, and entrypoints should not be activatable items.

When adding reorder features, update loader order only when the app can identify concrete activation references. Do not infer or rewrite complex loader code silently.

## UI Direction

- Settings should stay clean and grouped by topic.
- Sidebar should reflect config structure first: top-level `items`, `widgets`, `bar`, `themes`, `scripts`, then nested folders.
- Items may be grouped by SketchyBar position: left, center, right, unpositioned.
- Detail editor should group values into meaningful sections like item, icon, label, background, popup, scripts.
- Code preview is read-only context and should remain hideable.
- Boolean-like values should normalize to `true` / `false` unless SketchyBar has a special enum for that key, such as `updates = on/off/when_shown`.

## App-Only Theming

Current built-in themes are programming/color-scheme inspired: Nord, Dracula, Monokai, Tokyo Night, Catppuccin.

TintedThemingSwift may be useful later for Base16/Base24 palettes, but keep it app-local. Do not use TintedMac or injection-based tooling here because it can affect other macOS apps and requires unsafe system changes.

## Docs And Release

Keep these updated when behavior changes:

- `README.md` - user-facing install/features/limits.
- `CHANGELOG.md` - release notes.
- `docs/RELEASE_CHECKLIST.md` - release process.
- `.github` templates/workflows - contributor and CI behavior.

## Before Finishing

- Run `swift build` after code changes.
- Run `./script/build_and_run.sh --package` after packaging or bundle changes.
- Mention any command that could not run.
- Keep final notes concise and include touched files plus verification result.
