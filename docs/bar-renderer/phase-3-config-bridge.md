# Stage 3 — The config bridge

## Goal

A parsed config becomes a live item tree in the vendored SketchyBar. The app's existing SbarLua parser is the bridge: it reads the Lua of a config into item aliases and qualified key paths, and the app hands the equivalent property assignments to the vendored SketchyBar. A value that a config builds with an expression needs a Lua interpreter, so Stage 3b runs the config in the vendored Lua interpreter of the app and reads the values from there; SbarLua itself is still not vendored.

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
  -> add_item("clock", position: "right")
  -> set_item("clock", "position", "right")
  -> set_item("clock", "label.string", "10:00")
```

The position travels in the add command, because the daemon removes an item whose add position is missing or illegal (`src/message.c:202-208`). The position of the SbarLua style is a property of the table, so the bridge reads it from there and sends it with the add.

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

### The defaults of every file, not of one file

A config splits its defaults and its items over several files: the entrypoint requires the bar, the defaults and the items, the defaults live in their own file and the items live in a folder. `plan(forLua:)` reads one file, so the defaults of one file never reach the items of another.

The bridge therefore combines the plans of the files: `BarRenderPlan.combined(with:)` concatenates the defaults, merges the bar values, concatenates the items and concatenates the warnings. **The bridge collects the defaults of every file of the config and applies them before the first item of every file, so an item inherits the defaults of the whole config, not only the defaults of its own file.** The default item is a snapshot, so the order is the whole point: a default that comes after an item never reaches that item.

### The duplicate alias follows the daemon

The daemon answers "[?] Add: Item '%s' already exists" and returns when the name is taken (`src/message.c:190-193`). The item is therefore the one of the **first** declaration, and everything that only the add carries comes from that first add. Every `--set` after it still applies to the item, so the properties of a later declaration are applied and the last value of a property wins.

The two styles differ, and the difference is the daemon's own:

* In the SbarLua style the position is a **property** of the table (`sbar.add("item", "x", { position = "right" })`), so the position of the later declaration wins.
* In the shell style the position travels in the **add command** (`sketchybar --add item x right`), and the daemon refuses the whole second add, so the position of the first add wins.

The bridge reproduces that difference and reports it: "The alias 'clock' is added twice. SketchyBar keeps the first item; the properties of the second declaration are applied, and the last value of a property wins." The shell style adds: "The position of the second add is ignored."

### What the preview cannot show

The bridge names every value it cannot read, so the user learns what the preview does not show:

* A value that is built by an expression, such as `colors.red`, needs a Lua interpreter. The parser path keeps the value SketchyBar has by default and names the value: "The value of 'icon.color' is built by an expression, so the preview shows the value SketchyBar has by default, not the value of the config." The Lua path of Stage 3b reads the value instead.
* An alias that is built by an expression, such as `"menu." .. i`, cannot be shown: "The alias of an item is built by an expression, so the preview cannot show the item. SketchyBar shows it under the name of the expression."
* An item without a name is named by SbarLua: "The item has no name. SketchyBar gives it a generated name (item_0, item_1, ...), so the preview cannot show it."
* An item type the parser path cannot read, such as a graph or a bracket: "The 'graph' item 'cpu' shows no values yet, because the values come from the script that pushes them. The parser of the app cannot read the type of this item, so the preview does not show it." The Lua path reads the type and sends it to the preview, so the item reaches the preview and the wording of the type is the same: "The 'graph' item 'cpu' shows no values yet, because the values come from the script that pushes them. The preview lays it out with the width of the config."

## Files

**Create.** `Sources/SketchyBarStudio/Services/PreviewConfigBridge.swift`, `Sources/SketchyBarStudio/Models/BarRenderModels.swift`, `Sources/SketchyBarStudio/Models/BarRenderItemModel.swift`.

**Modify.** `Sources/SketchyBarStudio/Services/SbarLuaItemParser.swift` (or a new defaults parser next to it), `Sources/SketchyBarStudio/Services/ShellConfigScanner.swift`, `Sources/SketchyBarStudio/Models/StructuredItem.swift`, `Sources/CSketchyBar/include/sketchybar_preview.h` and `Sources/CSketchyBar/preview/sketchybar_preview_test.c` (the test-only accessor that serializes an item, so the tests can read the tree of the core). The app parses neither `sbar.default` nor `--default` today: `SbarLuaItemParser.swift:18` reads only `sbar.add` and `SbarLuaItemParser.swift:60` reads only `sbar.bar`, `ConfigScaffolder.swift:116` writes `sbar.bar({…})`, and `ShellConfigScanner.swift:82` and `ShellConfigScanner.swift:289-296` handle the `--bar` flag. The defaults need their own parse path, and it has to reach the default-item domain.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `Sources/SketchyBarStudio/Services/LuaTableParser.swift`, and any file under a user config root.

## Acceptance criteria

* A config with an item that sets `label.string`, `icon.string` and `background.color` produces an item tree with exactly those three properties.
* `sbar.default({...})` values reach every item that does not override them.
* `sketchybar --default k=v` in a shell config reaches every item that does not override them, the same way the SbarLua form does.
* The defaults are applied before the items are added, so the inheritance happens at item creation the way it does upstream.
* The defaults of one file reach the items of another file, because the bridge collects the defaults of every file of the config.
* A file with two `sbar.add("item", ...)` calls produces two items with distinct aliases.
* The bridge never writes to disk.
* A value of `icon.font.size` and a value of `label.font.size` on the same item stay in separate properties, and neither is read as the other.
* A shell config (`sketchybarrc` or a shell file) produces the same item tree as the equivalent SbarLua config. This holds for a config **without a duplicate alias**: a duplicate alias is not "the same thing said twice", and the daemon's own rule decides which of the two declarations wins (see above).
* Every value the bridge cannot read is named in its warnings, so the user learns what the preview does not show.

## Known limits

* The items of the plan follow the order of the files of the config, not the order in which the config loads them. The load order needs the load graph of the config, which [Stage 5](phase-5-preview-pane.md) owns.
* A value that is built by an expression cannot be read by the parser path, so that path keeps the value SketchyBar has by default. The Lua path of Stage 3b reads it.
* **The Lua path knows the load order and throws it away.** The defaults of a config are emitted before every item, so a default that the config declares after an item reaches an item the daemon would not give it to. Emitting the defaults at the place of the load needs an ordered list of the operations in `BarRenderPlan`, which is a bigger change than the fix pass of Stage 3b. The limit is known and not fixed yet.
* The Lua escapes are resolved in `SbarLuaItemParser`, and `Services/LuaTableParser.swift` resolves them a second time with other rules. The two resolvers have to become one, but `LuaTableParser.swift` is out of scope for this stage.

### Limits found by Stage 3d and not fixed

Stage 3d (the resolved pane: the draft applied on top of the resolved config, with the resolution cached by a disk signature) found three limits and fixed none of them. They are recorded here so a later stage does not re-discover them.

* **Drafts of non-plain items are ignored, and this is silent.** The parser of the app reads only the plain items, so a draft of a graph, a slider, a bracket, a space or an alias is not overlaid on the resolved item and the pane says nothing about it. The resolved config keeps the value from the disk, and the user's edit is lost without a word.
* **A draft cannot remove a resolved value.** The overlay only changes values the resolved item already has and adds values the draft introduces; it never deletes a value the resolved item has and the draft does not set. A user who deletes a key in the editor sees the old value stay on the bar.
* **Item attribution for items declared after their module finished loading points at the calling file.** The resolver names the file that was being run when the item was declared, so an item a module declares is attributed to the file that required the module and not to the module itself. The draft of the app matches on that same file, so the attribution is consistent, but it is not the file the user would open to edit the item.

### The disk-signature shortcut

The resolution of a config is the expensive half of a render, and the pane renders again on every keystroke of a draft. Stage 3d therefore keeps the resolved plan in a cache keyed by a **disk signature** of the config's files: the cache hashes the text of every file, its size and its content-modification date, and it re-runs the Lua only when one of them changes. A draft changes the text the app holds and not the text on disk, so a keystroke reuses the resolved config and only puts the draft on top of it. A file that changes on disk is a new signature and is resolved again. A run that fails is kept as well, so a config that runs into the deadline of the sandbox does not stop the pane on every keystroke. The signature is a shortcut, not a correctness claim: a file the app cannot see, or a file outside the config root, is not part of it.

## Tests

Unit tests in `Tests/SketchyBarStudioTests/PreviewConfigBridgeTests.swift`: one test per acceptance criterion, using the existing parser fixtures. The shared strategy is in [testing.md](testing.md).

Unit tests in `Tests/SketchyBarStudioTests/LuaConfigRunnerTests.swift` cover the Lua path of Stage 3b: the values of a config, the sandbox (the globals that are gone, the debug library, the read-only `io.open` and `io.output`, a file outside of the config root), the deadline of an endless loop, the generated names of the items without a name, an item type the daemon does not support, and the text of a number. The shared strategy is in [testing.md](testing.md).

## Risks and unknowns

* Open question 3: what exactly does `sbar.default({...})` do when a script overrides it? The defaults are applied to `default_item` (`src/bar_item.c:883-933`), but the order between a default set at load time and a later `--default` at runtime, and the behaviour when an item script sets a property that a default also sets, is not confirmed. Confirm before relying on the inheritance order. See [reference.md](reference.md#open-questions).
* The upstream inheritance is a snapshot at item creation (`src/bar_manager.c:463`, `src/bar_item.c:68`). The preview reproduces that by applying the defaults before the items are added. The open question is about the ordering against a *runtime* `--default`, not about the snapshot itself.
* Open question 4: the `icon` prefix semantics. If the reading in [reference.md](reference.md#the-icon-prefix-semantics--a-question-to-confirm) is confirmed, the fix belongs in this bridge and in the preview, not in a blind edit of `SketchyBarIcon`; the existing app behaviour for the `icon` property stays as it is until then.

## Done when

A parsed SbarLua config and a parsed shell config both produce the same item tree, the defaults reach every item that does not override them, the bridge writes nothing to disk, the unit tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
