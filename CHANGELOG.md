# Changelog

All notable changes to SketchyBar Studio will be documented here.

This project follows a human-readable changelog style and aims to use semantic versioning once tags begin.

## [Unreleased]

### Added

- The app has a Store that browses a curated catalogue of permissively licensed SketchyBar plugins and setups. A plugin installs as one file under `plugins/` plus one loader line, and the file content is shown before the write; a setup installs as a new profile, apart from the config the user already has. Every install is recorded in a manifest under Application Support, and uninstall removes exactly the recorded path and reverts exactly the recorded loader line, never a wildcard. The catalogue is embedded in the app and accepts only MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, Unlicense and CC0-1.0 entries, pinned to a tag or a commit; an entry with no verified licence is refused before any request. Downloads use one raw file request or one codeload tarball, with a 20 MB cap, a 2000 file cap, a 30 second timeout, and archive members with `..`, absolute paths or links are refused. The app never executes downloaded code, uses no GitHub token and makes no API calls. Selecting an entry also fetches its README, trying the entry directory first and then the three root spellings, capped at 256 KB and cached in memory per entry and ref; it is rendered as Markdown with a Rendered/Raw switch, falls back to plain text when parsing fails, and shows the source URL when nothing answers. Selecting a setup stages its tarball once, lists every file with its size and the total, and installs from that same staged tree, so the tarball is not fetched twice; the staging directory is dropped when the selection changes or the install sheet is dismissed, and the existing size, file-count and archive-member limits apply at staging time. The catalogue format, the verification checklist and the security policy are in `docs/store/README.md`.

- Multi-file plugin support: a plugin entry can declare additional files via the `files` array. Install writes the entry file and all extra files into `plugins/<entry id>/`, and the loader line references only the entry file. Uninstall removes the entire folder and reverts the loader line. A tampered manifest (path traversal, absolute path, or path outside the config) is refused before any deletion. Missing extra files abort the install before any loader edit. Four new multi-file plugins and three new setups were added, all MIT-licensed at pinned commits:
  - `aserranoni-sketchybar-brightness` (brightness slider with helper scripts)
  - `aserranoni-sketchybar-system-monitoring` (battery, CPU, memory items with shared plugins)
  - `lucasoesterbye-sketchybar-timewarrior` (Timewarrior tracker with menu, stats, and library)
  - `wthrajat-sketchybar-now-playing-shell` (shell variant of the now-playing item)
  - `logicsec-sketchybar-setup` (full Lua config with bar, items, widgets, C event providers)
  - `dividendsolo-omarchy-sketchybar` (shell config with AeroSpace, media, indicators, theme switching)
  - `pranav-js-sketchybar-config` (shell config with AeroSpace, system widgets, media)

- The Store now checks and installs external dependencies for catalogue entries. A `StoreDependency` declares a Homebrew formula, cask, command, font, or SketchyBar binary with a `required` flag. The install sheet shows each dependency, its presence state (present, missing, or unknown when brew/fontconfig is absent), and a per-sheet policy override. A settings control sets the user policy: "Never" (block install of entries with missing required deps), "Ask" (default, show deps before continuing), or "Automatic" (install Homebrew formula and cask deps automatically). After any automatic install, the service re-checks and surfaces an unresolved sheet when a required dependency is still missing, with a retry action. Dependency installs run only `brew install` with an argument array (never a shell string, never sudo), and brew absence is detected before any command is run.

- The `CLua` target vendors the Lua 5.5.0 interpreter, so the app can run the Lua of a config in the process and read the values the config really has. The upstream release that was vendored is recorded in `Sources/CLua/UPSTREAM.md`, the upstream MIT licence is in `Sources/CLua/LICENSE`, and every change made to the vendored code is listed in `Sources/CLua/MODIFICATIONS.md`. The vendored sources are byte-identical to the upstream release; the wrapper of the interpreter, `Sources/CLua/clua.c`, is new code of this project.
- A new bridge path resolves a config with a real Lua interpreter. The new `PreviewConfigBridge.plan(forLuaConfigRoot:)` runs the entrypoint of the config in a sandbox and returns the same plan the parser path returns, so a value that the config builds with an expression reaches the plan as the value of the config. The path is not wired to the preview yet, so the user sees no change. The run has a bounded allocator, a deadline and a sandbox that removes the globals a config must not use: `os.execute`, `os.exit`, `os.remove`, `os.rename`, `io.popen`, `dofile`, `loadfile`, `load` and `package.loadlib`. The path of the C modules is empty and the C searchers are gone, so no C module can load, and the module of SketchyBar is the shim of the app and never the real one. `io.open` only reads, `io.output`, `io.tmpfile` and `os.tmpname` cannot create a file, the debug library is out of reach, and a module that fails is a warning and not the end of the config. The sandbox is a guard against accidents and not a security boundary. When the run fails, the parser path is used and a warning says so. The existing API of the bridge does not change.
- The `CSketchyBar` target vendors a subset of the SketchyBar C code as a headless preview core. It exports `sb_preview_create` and `sb_preview_destroy`. The upstream commit that was vendored is recorded in `Sources/CSketchyBar/UPSTREAM.md`, the upstream licence is in `Sources/CSketchyBar/LICENSE.md`, and every change made to the vendored code is listed in `Sources/CSketchyBar/MODIFICATIONS.md`.
- The preview core grows a headless item tree and a C API for it: `sb_preview_set_bar`, `sb_preview_set_default`, `sb_preview_add_item`, `sb_preview_set_item`, `sb_preview_set_display`, `sb_preview_set_menu_bar` and `sb_preview_messages`. The default item is a snapshot taken when an item is created, exactly like `sketchybar --default`, and the virtual display has a configurable frame, the fixed backing scale of 2.0 of SketchyBar and a modelled menu bar. Every function that returns a number answers 0 when it succeeded; the codes are listed in `Sources/CSketchyBar/include/sketchybar_preview.h`.
- The app's parsers become the property assignments of the preview core. The config bridge turns a parsed SbarLua or shell config into the item tree of the preview: it reads `sbar.default({…})` and `sketchybar --default`, the properties of the default item, and it applies the defaults before the items, so every item inherits them the way it does in SketchyBar. The defaults of every file of a config are collected, so an item inherits the defaults of the whole config and not only the defaults of its own file. A value that is built by an expression, such as colors.red, cannot be read without a Lua interpreter, so the preview keeps the value SketchyBar has by default and names the value in its warnings. A property the vendored code refuses is reported with the reason of the vendored code. The bridge only reads the config and never writes to it.
- A NOTICE file names the upstream projects whose code the app will vendor, states that the vendored code is modified, and points at where the complete source of a release can be found.
- The preview core lays a bar out and paints it into a bitmap, with no window server, no screen recording permission and no running SketchyBar. The new `sb_preview_render` returns the image, `sb_preview_item_rect` returns the rectangle of an item, `sb_preview_bar_frame` returns the frame of the bar and `sb_preview_release_image` releases the image. The image is the frame of the bar, in points, at the fixed backing scale of 2.0 of SketchyBar, so every rectangle of the API is in points and the bitmap is twice the size of the point geometry. The add of an item takes the four arguments of the add command of the daemon, so the preview core can hold an alias or a space item and can lay out a graph, a slider or a ring; an alias or a space item needs the window server, so it keeps a placeholder box of 16 points. The parser path of the config bridge keeps only the plain items: in the config of the maintainer, 77 items are shown and the 36 items of the other types are reported as unsupported. The path that runs the config in the Lua interpreter keeps every type. The notch of the virtual display is a parameter of the display, so a notched Mac can be reproduced.
- The item types of a config reach the preview. A config that a Lua interpreter resolved keeps its graphs, brackets, spaces and sliders: they reach the item tree of the preview as items instead of being skipped. A graph and a slider are laid out with the width of the config and show no values yet, because the values come from the script that pushes them. An alias and a space are shown as a placeholder, because they need the window server. A bracket groups its members and draws the background around them, the way SketchyBar does. An event is not shown on the bar at all, because SketchyBar registers the event and draws nothing for it. The name of an alias holds the owner and the name of the menu bar item, split at a comma, and the preview copies the two halves the way the daemon does, so an alias whose name holds a comma does not break the preview when it is destroyed. The preview pane still reads the config with the parser, which keeps only the plain items, so the change is visible as soon as the path that runs the config in the Lua interpreter is wired to the pane.
- The detail view has a Preview pane that shows the rendered bar of any config or profile in the library. The Edit/Preview switch chooses between the editor and the pane, and switching never loses a draft, because the drafts live in the store. The picker names the config or the profile the bar comes from, and the config the app has open is one of the choices, not the only one; the render of that config shows the unsaved drafts, every other config and every profile is shown as it is on disk, and the pane says so. The bar is drawn at its true size and the view applies one uniform factor that fits the pane, so the real menu-bar proportions survive and the bar is never stretched or re-laid out to the shape of the pane. A 1:1 switch shows the bar at its true point size, so one image pixel lands on one device pixel on a 2× display, and the pane scrolls sideways then. The render uses the width of the target display in points, the picker lets the user choose the display and offers a width override, and the width that is used is shown. The render runs off the main thread, and a render that is older than the newest one is dropped.
- The item scripts run inside the preview, so the bar shows live values. The scripts are isolated: they cannot change the real SketchyBar. A script of an item runs the way the daemon runs it, with the environment of the item itself, and its `sketchybar --set` calls reach a shim that stands in for the binary of the daemon instead of the daemon. The shim is first on the `PATH` of the child, the directory of the real binary is not on it at all, and the shim never forwards a command it does not handle: such a command is a warning in the pane and nothing else. A script that calls the binary by its own path is not intercepted, and the pane warns about it.
- The previewed bar can be pushed to the running SketchyBar, under the control of a setting. The picker holds the three modes: `Never` (the safe one, and the one a fresh install starts with), `On Apply` (the live bar is updated when the user clicks Apply or Save & Apply) and `While Editing` (the live bar is updated as the user edits, throttled to one push every 0.6 seconds). The picker sits in the editor pane and in the preview pane, so the mode is visible where the user writes. The push is allowed for the live config of SketchyBar only: for every other config the app says which config the preview shows and refuses the push, so the values of another config never reach the bar of the user. The picker of the mode stays on in every case, because the mode is a setting and the user must be able to go back to `Never`. The push sends one `sketchybar --set <item> <property>=<value>` call per declared item, with the values of the config and not their spelling, and a value with a space keeps its space. A script is never pushed: a script belongs to the config and not to the running bar. The position of an item is never pushed either: the position is structure and not a value, and pushing it would move the item into a popup. The settings of the bar itself, such as its height, its margin and its colors, are never pushed by the mode: they change the bar the user looks at, so only the new "Apply Bar Settings" button pushes them, and it asks first and names the config and every property with the value it has now and the value it gets. The daemon is asked first, and nothing is pushed when it does not answer; the app never starts it. Before the first push of a session the app says how many items, how many properties and how many properties of the bar really change on the live bar. A snapshot of the live bar is taken before the push and written to the Application Support of the app, so the new "Restore Bar" button puts the live bar back, also after a restart of the app. A restore that cannot put everything back says what could not be put back and leaves the rest alone. Only one push runs at a time: a request that comes in while a push runs waits for it, so a slow push cannot win over the values the user typed last. An alias that the config declares twice is a known limit: the preview merges the two declarations into one item and keeps the last value of a property, while the running SketchyBar keeps the first item of the alias (`src/message.c:189-193`). The push can therefore set a value the running bar does not have, and the next reload of the config undoes it.

### Changed

- The project licence is now GPL-3.0 instead of MIT. The full licence text is in LICENSE.
- The install instructions now point at the consolidated Homebrew tap `wiggly-sheets/homebrew-tap`. The old tap `wiggly-sheets/sketchybar-studio` is deprecated. Move over with `brew untap wiggly-sheets/sketchybar-studio` and `brew tap wiggly-sheets/homebrew-tap`.

## [1.0.2] - 2026-10-20

### Added

- SbarLua item tables are now read with their real structure. A value inside a nested table keeps its full path, such as `icon.font.size` or `background.border_color`, instead of a flat `size` or `border_color` that could belong to any part of the item. The values are grouped by the part of the item they belong to, and the option reference shows the entry of the exact key.
- Most SketchyBar options now have a reference entry: an info button next to the key path opens a popover with the meaning, the type, the accepted values and the default of the option. The summary is also part of the tooltip of the value editor.
- The dropdown suggestions come from the SketchyBar property table instead of a short hand written list, so options such as `symbol_mode`, `anchor` and `cap` now offer their real values.
- Quitting now asks what to do with unsaved edits: Save All, Discard, or Cancel. Closing the last window keeps the app alive while drafts exist.
- Files that disappeared from disk keep their session and draft. They are listed in a "Missing Files" section of the sidebar and the draft comes back when the file returns.
- The structured editor shows a file's read error, marks the sidebar row with a red dot, and disables the value editors and the save button for that file.
- A reachability map shows what SketchyBar really loads. The new toolbar button opens a sheet with the files no loader reaches, the loader lines that point at files that are gone, and the require cycles. The map only reads the config and never changes it.
- A config validator finds the problems SketchyBar ignores. The new "Diagnostics" toolbar button opens a sheet with the unknown options of an item, the values SketchyBar cannot use, the aliases that are used twice, the loader lines that point at a file that is gone, the files no loader reaches, the files with unbalanced brackets, and the item files that declare nothing. Every finding names the file and the line, and clicking it reveals the file in Finder. The validator only reads the config and never changes it.
- A duplication finder shows the item files of the config that are nearly the same. The new "Duplicates" toolbar button opens a sheet with the pairs of files that match, how much they match, and the keys that drifted apart with both values side by side. A slider tightens or loosens the match, and every file can be revealed in Finder. The finder only reads the config and never changes it.
- Undo and redo for value edits, source edits, discards, loader reorders and activation toggles. The Edit menu names the change that will be undone, and Cmd-Z and Cmd-Shift-Z do the same. Several edits of the same value in one run are one step, so holding a key down does not fill the history. An undo that cannot be applied safely, because the file changed on disk in the meantime, is reported and stays in the history.
- The bar preview draws the real item: an SF Symbol, the icon of an installed app, a media artwork or the text of the icon, the real label, and the font, the text color and the background color of the config. An SF Symbol that SketchyBar would reject is shown with a warning, and an app that is not installed is shown with a placeholder.
- A save is reviewed before it is written. The sheet shows the file on disk and the text that would be written, line by line, so a change can be checked before it reaches the file. The file is written only after the change is accepted.
- A wizard that creates new bar items. The "Add Item" toolbar button opens a sheet with ready made items such as clock, battery, volume, Wi-Fi, media, space, front app and a plain custom item. The wizard checks the name, the position and the icon while you type, shows the exact file text before anything is written, writes the file in the folder you choose, and adds the matching `require(...)` line to the loader file. An existing file is only replaced after a confirmation and is kept in the backups folder. Creating the file and adding the loader line are two undo steps, so Cmd-Z takes them back one by one.
- A clone action for an existing item. The context menu of a file in the sidebar offers "Clone Item…", which copies the file with a new name and a new alias. Only the alias of the `sbar.add("item", …)` call changes, every other line of the file stays the same, and the sheet shows the exact text before anything is written. The copy lands in the folder of the source and the matching `require(...)` line is added to the loader file. A file that already exists is never overwritten, a file without an item is copied without a loader line, and creating the copy and adding the loader line are two undo steps.
- A global search finds a file or an option in any file of the config. The new "Quick Open…" command (Cmd-P) opens a sheet that searches the names of the files and the options of every file. Picking a file opens it, and picking an option opens the file and narrows the editor down to that option.
- A new config from a template. The "New Config…" button in the settings of the config library opens a sheet that writes a complete, working SketchyBar config, in SbarLua or in shell style: the entrypoint, the bar, a colour theme, a table of icons and the items you pick. The sheet shows the files that will be written and the text of the file that is picked, a folder that already holds a config is never written into, a folder that is not empty needs a confirmation, and a file that is replaced is kept in the backups folder. The whole creation is one undo step, so Cmd-Z takes the files and the entry of the library back.

### Changed

- The code preview shows the pending draft instead of the file on disk, so the preview and the editor no longer disagree.
- Reloading the config and running `sketchybar --reload` no longer block the window. The reload happens in the background, and `sketchybar --reload` is stopped after 10 seconds instead of waiting forever on a permission prompt.
- The sidebar lists the categories in the documented order: items, widgets, bar, themes, scripts.
- The source editor shows line numbers next to the text.
- The Settings window uses the same dark scheme as the main window, and the folder picker opens as a sheet.
- A shell value keeps the quoting it has in the file. A double quoted value keeps its `$` and backtick live, a single quoted value stays single quoted and literal, and an unquoted value stays unquoted when it is a safe word.
- The shell scanner only offers values that are SketchyBar options. Function locals such as `local result=5` and loop counters are no longer listed as editable options, while `export FOO=bar` still is.
- A `sketchybarrc` that holds Lua code is read as Lua. Its `require(...)` lines are loader references, so the files they load can be switched off and ordered.
- The build and the release run through a Makefile now. `make help` lists the targets, `make build` builds the package, `make test` runs the test suite, `make app-universal` builds the universal bundle, `make dmg-universal` builds the disk image, and `make release-artifacts VERSION=x.y.z` writes the disk image and its checksum sidecar next to it. `make release VERSION=x.y.z` builds the artifacts and creates the tag without pushing anything.
- The release workflow uses the same targets, and the release notes come from the section of this changelog for the released version. A release without such a section fails.

### Fixed

- The properties of the bar are no longer read as the properties of an item. A `sbar.bar({ … })` table and a `sketchybar --bar position=top` line now use the bar level of the option reference, so `position = "top"` in a `bar.lua` is no longer reported as an invalid value, and the dropdown of a bar property offers the values of the bar, such as `top` and `bottom` for `position`.
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
- The code preview no longer writes the offsets of an older version of the file into the text the app holds. A file that changed on disk is read again, and a preview that cannot be built is reported instead of ending the app.
- Undoing the creation of a file no longer takes the loader line away when the file changed on disk. The content of the file is compared first, so a refused undo changes nothing.
- Undoing the replacement of a file puts the original bytes back, even when the file is not plain UTF-8 text. A file whose bytes cannot be read is never replaced, because such a change could not be undone.
- A step of the history whose value is gone is dropped instead of blocking every later undo. The same holds for the redo history.
- A folder of the config that points outside the config folder is refused when a file is created in it. A config folder that is itself a symlink still works.
- A loader file with an unsaved source draft is not changed when a new loader line is added, because that draft could never be saved afterwards.
- The save review compares the change with the text the app holds, so the edit of another program is not shown as being reverted. A file that changed on disk gets a notice.

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
