# Stage 3 — The config bridge

## Goal

A parsed config becomes a live item tree in the vendored SketchyBar. The app's existing SbarLua parser is the bridge: it reads the Lua of a config into item aliases and qualified key paths, and the app hands the equivalent property assignments to the vendored SketchyBar, so no Lua interpreter and no SbarLua are needed in the app.

## Depends on

[Stage 2](phase-2-headless-core.md) must be merged. The bridge writes into the item tree that Stage 2 exposes.

## In scope / Out of scope

**In scope.** `PreviewConfigBridge`, the bar defaults, the shell config style, several items per file, and the key path of every value.

**Out of scope.** The layout ([Stage 4](phase-4-layout-and-render.md)), the preview pane ([Stage 5](phase-5-preview-pane.md)), and any change to the user's config files.

## Tasks

1. Write `PreviewConfigBridge`: turn `StructuredItem` values and the bar values into `sb_preview_add_item` / `sb_preview_set_item` / `sb_preview_set_bar` calls.
2. Handle `sbar.default({...})` and `sketchybar --default k=v`: parse them and apply them as the bar's defaults, so every item inherits them.
3. Support the shell config style (`sketchybarrc` and shell files) through the same bridge.
4. Support several items per file: the bridge must not assume one alias per file.
5. Keep the key path of every value, so a value that comes from a table such as `icon.font.size` is not confused with `label.font.size`.

### How the bridge maps a parsed key path to a SketchyBar property

```
sbar.add("item", "clock", { position = "right", label = { string = "10:00" } })
  -> add_item("clock")
  -> set_item("clock", "position", "right")
  -> set_item("clock", "label.string", "10:00")
```

SketchyBar's property parser accepts dotted property names, and the SbarLua README states that all dots are substituted by sub-tables. `icon.string` is therefore a first-class SketchyBar property.

The app already parses SbarLua into an item alias plus qualified key paths (`Services/SbarLuaItemParser.swift`, `Services/LuaTableParser.swift`, `Models/StructuredItem.swift`). The app already extracts the item alias (`sbar.add("item", "<alias>", {…})`) and knows the alias per item block, and one file can declare several items.

Values keep their SketchyBar spelling: colours stay `0xAARRGGBB`, booleans stay `true` / `false` except where SketchyBar has an enum such as `updates = on/off/when_shown`.

The bar defaults come from `sbar.default({...})` and `sketchybar --default k=v` and are applied through the same `sb_preview_set_bar` path, so every item inherits them the way SketchyBar does. Every item inherits the bar's `default_item` (`src/bar_item.c:883-933`); a preview that ignores them cannot be exact.

## Files

**Create.** `Sources/SketchyBarStudio/Services/PreviewConfigBridge.swift`, `Sources/SketchyBarStudio/Models/BarRenderModels.swift`, `Sources/SketchyBarStudio/Models/BarRenderItemModel.swift`.

**Modify.** None outside the two new model files. The app's existing parsers are used as they are.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `Sources/SketchyBarStudio/Services/SbarLuaItemParser.swift`, `Sources/SketchyBarStudio/Services/LuaTableParser.swift`, and any file under a user config root.

## Acceptance criteria

* A config with an item that sets `label.string`, `icon.string` and `background.color` produces an item tree with exactly those three properties.
* `sbar.default({...})` values reach every item that does not override them.
* A file with two `sbar.add("item", ...)` calls produces two items with distinct aliases.
* The bridge never writes to disk.
* A value of `icon.font.size` and a value of `label.font.size` on the same item stay in separate properties, and neither is read as the other.
* A shell config (`sketchybarrc` or a shell file) produces the same item tree as the equivalent SbarLua config.

## Tests

Unit tests in `Tests/SketchyBarStudioTests/PreviewConfigBridgeTests.swift`: one test per acceptance criterion, using the existing parser fixtures. The shared strategy is in [testing.md](testing.md).

## Risks and unknowns

* Open question 3: what exactly does `sbar.default({...})` do when a script overrides it? The defaults are applied to `default_item` (`src/bar_item.c:883-933`), but the order between a default set at load time and a later `--default` at runtime, and the behaviour when an item script sets a property that a default also sets, is not confirmed. Confirm before relying on the inheritance order. See [reference.md](reference.md#open-questions).
* Open question 4: the `icon` prefix semantics. If the reading in [reference.md](reference.md#the-icon-prefix-semantics--a-question-to-confirm) is confirmed, the fix belongs in this bridge and in the preview, not in a blind edit of `SketchyBarIcon`; the existing app behaviour for the `icon` property stays as it is until then.

## Done when

A parsed SbarLua config and a parsed shell config both produce the same item tree, the bar defaults reach every item that does not override them, the bridge writes nothing to disk, the unit tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
