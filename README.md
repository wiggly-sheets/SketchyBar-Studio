<div align="center">

  <img src="Assets/SketchyBarStudioLogo.svg" width="144" alt="SketchyBar Studio logo" />

  <h1>SketchyBar Studio</h1>

  <p><b>Edit your SketchyBar config. Keep it yours.</b></p>

  <p>
    A native macOS editor for existing SketchyBar configurations.<br/>
    Safer edits, clearer structure, and backups before every write.
  </p>

  <p>
    <a href="https://github.com/wiggly-sheets/SketchyBar-Studio/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/wiggly-sheets/SketchyBar-Studio/ci.yml?branch=master&label=build" alt="Build status" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/wiggly-sheets/SketchyBar-Studio?color=blue" alt="License: MIT" /></a>
    <a href="https://github.com/wiggly-sheets/SketchyBar-Studio/releases/latest"><img src="https://img.shields.io/github/v/release/wiggly-sheets/SketchyBar-Studio?label=latest&color=red" alt="Latest release" /></a>
  </p>

  <p>
    <a href="https://github.com/wiggly-sheets/SketchyBar-Studio/releases/latest"><b>Download</b></a>
    &nbsp;·&nbsp;
    <a href="#installation">Install guide</a>
    &nbsp;·&nbsp;
    <a href="#build-from-source">Build from source</a>
    &nbsp;·&nbsp;
    <a href="#safety">Safety</a>
  </p>

  <img width="1425" height="1045" alt="SketchyBar Studio editing a SketchyBar configuration" src="https://github.com/user-attachments/assets/8554a595-df01-480f-86d6-be08b555d6e7" />

</div>

---

SketchyBar Studio helps you explore and edit the SketchyBar setup you already have, without turning your configuration into an app-owned project. It follows your folder structure, provides native controls for common values, and keeps writes narrow and backed up.

> [!NOTE]
> Your configuration remains ordinary Lua, `sketchybarrc`, and shell files. Studio does not replace the files or take ownership of them.

---

## Features

### Your configuration, made navigable

- Opens `~/.config/sketchybar` by default, or any other SketchyBar config folder.
- Supports Lua files alongside `sketchybarrc`, `.sketchybarrc`, and shell-based configurations.
- Presents a path-first sidebar: `items`, `widgets`, `bar`, `themes`, and `scripts`, including nested folders. Item folders named `left`, `center`, or `right` are recognized directly; otherwise items are grouped from their simple `position` values, including compact Lua item tables.
- Finds files and editable values with search, and can show only unsaved changes.
- Keeps a read-only, hideable code preview close to the editor. The preview shows the pending draft, so it matches what will be written to disk.

### Purpose-built editing

- Uses dropdowns for known SketchyBar options and toggles for ordinary booleans.
- Shows an option reference for every known option: an info button next to the key path opens a popover with the meaning, the type, the accepted values and the default of the option.
- Includes an interactive draft bar preview: drag items to reorder them or move them between left, center, and right; drag a numeric-width handle to resize; and adjust available left/right padding without writing files until you save.
- Provides a built-in source editor for complete Lua and `sketchybarrc` files, with optional Vim-style navigation (`h/j/k/l`, words, line start/end, `i`/`a`, Escape). Source saves use the same backup protection as structured edits.
- Opens the native macOS color picker, saving colors as `0xAARRGGBB`.
- Opens the native macOS font panel, saving SketchyBar font syntax.
- Groups controls into practical sections such as item, icon, label, background, popup, and scripts.
- Normalizes boolean-style values to `true` and `false`, while preserving SketchyBar-specific choices such as `updates = on/off/when_shown`.

### Activation and ordering

- Turns loader-backed items on or off by commenting or uncommenting their loader references.
- Detects common Lua and shell loader patterns in `init.lua`, `sketchybarrc`, `.sketchybarrc`, and related loader files.
- Reorders items when Studio can identify concrete activation references; complex loader code is left alone.
- Avoids offering core entrypoints and theme files as activatable items.

### Config library and profiles

- Keeps a library of config folders, including symlinked configs in dotfiles repositories.
- Saves and restores full config-folder snapshots as per-config profiles.
- Can make a selected config live by pointing `~/.config/sketchybar` at it, with a confirmation step and backup of an existing real folder.
- Saves all edits and optionally runs `sketchybar --reload` to apply them.

### Native macOS experience

- Built as a native SwiftUI app for macOS 14 and later.
- Uses familiar macOS controls, including file panels, color picker, font panel, settings, and split views.
- Includes Nord, Dracula, Monokai, Tokyo Night, and Catppuccin app-only themes.

---

## Download

<div align="center">

<a href="https://github.com/wiggly-sheets/SketchyBar-Studio/releases/latest"><img src="https://img.shields.io/badge/download-SketchyBar%20Studio-2EA043?style=flat&logo=apple&logoColor=white" alt="Download SketchyBar Studio" /></a>

</div>

---

## Installation

SketchyBar Studio preview builds are ad-hoc signed, but not Developer ID signed or notarized. You can install the universal DMG release or build it yourself.

### Install with Homebrew

```bash
brew tap wiggly-sheets/sketchybar-studio
brew trust wiggly-sheets/sketchybar-studio
brew install --cask sketchybar-studio
```

### Install from a release

1. Download the universal `.dmg` from the [latest release](https://github.com/wiggly-sheets/SketchyBar-Studio/releases/latest).
2. Open the DMG and drag **SketchyBar Studio** to your Applications folder.
3. Open the app from Applications.

### Opening a preview build

Because preview builds are not Developer ID signed or notarized, macOS may block the first launch. Open **System Settings → Privacy & Security** after that attempt and choose **Open Anyway**, or Control-click the app and choose **Open**.

If macOS still blocks an app that you downloaded from a source you trust, remove its quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/SketchyBarStudio.app
```

If the app lives elsewhere, use its actual path instead.

---

## Safety

SketchyBar Studio is deliberately conservative about config changes.

| What Studio does | What that means |
| --- | --- |
| Makes copies under `backups/` before writing | You have a local backup of the original file before an edit is saved. |
| Edits simple scalar assignments | Complex Lua tables and computed values are not silently rewritten. |
| Follows folders and symlinks | A config stored in a dotfiles repository remains in place. |
| Changes loader order only when references are clear | Unusual or complex loader logic is not inferred or rewritten. |
| Keeps unsaved edits in memory and asks before quitting | Quitting with unsaved edits offers Save All, Discard, or Cancel instead of dropping them. |
| Keeps drafts when a file changes on disk | A draft follows its value even when lines move, and it is reported when the value is gone. |

You can use the GUI for routine changes and keep the code preview open whenever you want to verify the underlying configuration.

---

## Build from source

### Requirements

- macOS 14 or later
- Xcode with Swift 5.9 or later
- [SketchyBar](https://github.com/FelixKratz/SketchyBar) installed when testing live reload behavior

### Clone and run

```bash
git clone https://github.com/wiggly-sheets/SketchyBar-Studio.git
cd SketchyBar-Studio
./script/build_and_run.sh
```

To build without launching:

```bash
swift build
./script/build_and_run.sh --package
```

The packaged app is written to `dist/SketchyBarStudio.app`.

### Build a universal app

To package a release-style app for both Apple Silicon and Intel Macs:

```bash
./script/build_and_run.sh --universal-package
lipo -info dist/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
```

---

## Known limits

- Lua editing intentionally targets simple scalar assignments first; tables and computed values remain read-only context.
- Shell support covers common `key=value` SketchyBar property assignments.
- Unusual loader patterns may require future activation-detection support.

## Inspiration

SketchyBar Studio is built for the ecosystem around:

- [SketchyBar](https://github.com/FelixKratz/SketchyBar) — the macOS menu bar customization tool it edits and supports.
- [SbarLua](https://github.com/FelixKratz/SbarLua) — the Lua API used by many modern SketchyBar configurations.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and pull-request guidance.

## License

MIT. See [LICENSE](LICENSE).
