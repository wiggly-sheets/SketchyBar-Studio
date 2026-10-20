# Stage 3 — The config bridge

## Goal

A parsed config becomes a live item tree in the vendored SketchyBar. The app's existing SbarLua parser is the bridge: it reads the Lua of a config into item aliases and qualified key paths, and the app hands the equivalent property assignments to the vendored SketchyBar, so no Lua interpreter and no SbarLua are needed in the app.

## Depends on

[Stage 2](phase-2-headless-core.md) must be merged. The bridge writes into the item tree that Stage 2 exposes.

## In scope / Out of scope

**In scope.** `PreviewConfigBridge`, the bar defaults, the default-item properties, the shell config style, several items per file, and the key path of every value.

**Out of scope.** The layout ([Stage 4](phase-4-layout-and-render.md)), the preview pane ([Stage 5](phase-5-preview-pane.md)), and any change to the user's config files.

## Tasks

1. Write `PreviewConfigBridge`: turn `StructuredItem` values and the bar values into `sb_preview_add_item` / `sb_preview_set_item` / `sb_preview_set_bar` / `sb_preview_set_default` calls.
2. Parse `sbar.default({...})` and `sketchybar --default k=v`, and apply them through `sb_preview_set_default`, **before** any `sb_preview_add_item` call. They are the properties of the default item, not of the bar.
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

### The defaults are the default item, and the inheritance is a snapshot

`--default` is **not** a bar property. The help text calls it "Change default properties for new items" (`src/misc/help.h:12-13`), and the server routes it to `bar_item_parse_set_message(&g_bar_manager.default_item, …)` (`src/message.c:335`), which is a different domain from `--bar`.

Inheritance happens **once, when the item is created**: `bar_manager_create_item` calls `bar_item_init(bar_item, &bar_manager->default_item)` (`src/bar_manager.c:463`), which calls `bar_item_inherit_from_item` (`src/bar_item.c:68`, body `src/bar_item.c:883-933`). A default that is set after an item exists never reaches that item, and the C API has no way to reach it afterwards.

The bridge therefore has to do two things in this order:

1. Collect every `sbar.default({...})` value and every `sketchybar --default k=v` value from the config, and hand them to `sb_preview_set_default`.
2. Only then add the items, with `sb_preview_add_item`.

A default that the item does not override is then inherited by the item, and the acceptance criterion "defaults reach every item that does not override them" holds.

## Files

**Create.** `Sources/SketchyBarStudio/Services/PreviewConfigBridge.swift`, `Sources/SketchyBarStudio/Models/BarRenderModels.swift`, `Sources/SketchyBarStudio/Models/BarRenderItemModel.swift`.

**Modify.** `Sources/SketchyBarStudio/Services/SbarLuaItemParser.swift` (or a new defaults parser next to it), `Sources/SketchyBarStudio/Services/ShellConfigScanner.swift`, `Sources/SketchyBarStudio/Models/StructuredItem.swift`. The app parses neither `sbar.default` nor `--default` today: `SbarLuaItemParser.swift:18` reads only `sbar.add` and `SbarLuaItemParser.swift:60` reads only `sbar.bar`, `ConfigScaffolder.swift:116` writes `sbar.bar({…})`, and `ShellConfigScanner.swift:82` and `ShellConfigScanner.swift:289-296` handle the `--bar` flag. The defaults need their own parse path, and it has to reach the default-item domain.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `Sources/SketchyBarStudio/Services/LuaTableParser.swift`, and any file under a user config root.

## Acceptance criteria

* A config with an item that sets `label.string`, `icon.string` and `background.color` produces an item tree with exactly those three properties.
* `sbar.default({...})` values reach every item that does not override them.
* `sketchybar --default k=v` in a shell config reaches every item that does not override them, the same way the SbarLua form does.
* The defaults are applied before the items are added, so the inheritance happens at item creation the way it does upstream.
* A file with two `sbar.add("item", ...)` calls produces two items with distinct aliases.
* The bridge never writes to disk.
* A value of `icon.font.size` and a value of `label.font.size` on the same item stay in separate properties, and neither is read as the other.
* A shell config (`sketchybarrc` or a shell file) produces the same item tree as the equivalent SbarLua config.

## Tests

Unit tests in `Tests/SketchyBarStudioTests/PreviewConfigBridgeTests.swift`: one test per acceptance criterion, using the existing parser fixtures. The shared strategy is in [testing.md](testing.md).

## Risks and unknowns

* Open question 3: what exactly does `sbar.default({...})` do when a script overrides it? The defaults are applied to `default_item` (`src/bar_item.c:883-933`), but the order between a default set at load time and a later `--default` at runtime, and the behaviour when an item script sets a property that a default also sets, is not confirmed. Confirm before relying on the inheritance order. See [reference.md](reference.md#open-questions).
* The upstream inheritance is a snapshot at item creation (`src/bar_manager.c:463`, `src/bar_item.c:68`). The preview reproduces that by applying the defaults before the items are added. The open question is about the ordering against a *runtime* `--default`, not about the snapshot itself.
* Open question 4: the `icon` prefix semantics. If the reading in [reference.md](reference.md#the-icon-prefix-semantics--a-question-to-confirm) is confirmed, the fix belongs in this bridge and in the preview, not in a blind edit of `SketchyBarIcon`; the existing app behaviour for the `icon` property stays as it is until then.

## Done when

A parsed SbarLua config and a parsed shell config both produce the same item tree, the defaults reach every item that does not override them, the bridge writes nothing to disk, the unit tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
