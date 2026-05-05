<p align="center">
  <img src="Assets/SketchyBarStudioLogo.svg" width="144" alt="SketchyBar Studio logo">
</p>

# SketchyBar Studio

Native macOS companion app for editing SketchyBar configs without hand-editing every value.

SketchyBar Studio discovers your existing SketchyBar setup, presents editable values in a native GUI, and keeps file writes conservative so your config stays yours.

## Features

- Open a SketchyBar config folder, defaulting to `~/.config/sketchybar`.
- Support Lua config files plus old-school `sketchybarrc`, `.sketchybarrc`, and shell script files.
- Browse config files in path-first sidebar groups.
- Activate/deactivate items by commenting or uncommenting matching loader lines.
- Edit scalar values with purpose-built controls:
  - dropdowns for known SketchyBar choices
  - native color picker with opacity, saved as `0xAARRGGBB`
  - native macOS font panel, saved as SketchyBar font syntax
  - toggles for booleans
- Save `.studio-backup` copies before writing.
- Save profiles as full config folder snapshots.
- Search files and values.
- Show changed values only.
- Save all changes and apply with `sketchybar --reload`.
- Choose code-inspired app themes: Nord, Dracula, Monokai, Tokyo Night, Catppuccin.

## Screenshots

<img width="1425" height="1045" alt="SCR-20260505-lilj" src="https://github.com/user-attachments/assets/8554a595-df01-480f-86d6-be08b555d6e7" />

## Install

SketchyBar Studio is currently distributed as unsigned preview builds. You have three install options.

### Option 1: Download the Release Zip

1. Go to the GitHub Releases page.
2. Download `SketchyBarStudio-universal.app.zip`.
3. Unzip it.
4. Move `SketchyBarStudio.app` to `/Applications`.

### Option 2: Homebrew Cask from Custom Tap

A custom Homebrew tap can install the release zip as a cask:

```bash
brew tap wiggly-sheets/sketchybar-studio
brew install --cask sketchybar-studio
```

Or in one command:

```bash
brew install --cask wiggly-sheets/sketchybar-studio/sketchybar-studio
```

Replace `YOUR-USER` with the GitHub account that hosts the tap.

### Option 3: Build from Source

```bash
git clone https://github.com/wiggly-sheets/sketchybar-studio.git
cd sketchybar-studio
./script/build_and_run.sh
```

For a local `.app` bundle:

```bash
./script/build_and_run.sh --package
open dist/SketchyBarStudio.app
```

For a universal release bundle that supports Apple Silicon and Intel Macs:

```bash
./script/build_and_run.sh --universal-package
lipo -info dist/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
```

## Opening Unsigned Builds

Early GitHub release builds are unsigned and not notarized. macOS may block the app no matter how you installed it: release zip, Homebrew cask, or local source build.

Try opening it through **System Settings > Privacy & Security** after the first blocked launch, or right-click `SketchyBarStudio.app` and choose **Open**. If macOS still blocks it, remove the quarantine attribute manually:

```bash
xattr -dr com.apple.quarantine /Applications/SketchyBarStudio.app
```

If you run it from another folder, replace `/Applications/SketchyBarStudio.app` with the actual app path.

Only run this command for apps you downloaded from a source you trust.

## Known Limits

- The Lua editor intentionally edits simple scalar assignments first. Complex tables and computed values stay untouched.
- Shell support handles common `key=value` SketchyBar property assignments.
- Activation detection looks for references in `init.lua`, `sketchybarrc`, and `.sketchybarrc`; unusual loaders may need later pattern support.

## Run

```bash
./script/build_and_run.sh
```

Xcode can also open the Swift package directly.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
