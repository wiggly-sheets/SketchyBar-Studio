# Test strategy

This file holds the strategy that every stage of the bar renderer shares. The per-stage test requirements stay in the stage files; this file says what the tests are for, what they need, and how they are run.

Run the suite with `swift test` from the repository root. A stage is done when its own tests pass, the whole suite passes, and master is green.

## Unit tests

* `PreviewConfigBridgeTests.swift`: the bridge maps key paths to properties, applies the defaults to the default item before the items are added, handles several items per file, and never writes.
* `LuaConfigRunnerTests.swift`: the Lua path resolves the values of a config in the vendored Lua interpreter, names the items without a name like the daemon does, and keeps the sandbox in place: the globals a config must not use are gone, the debug library is out of reach, `io.open` only reads, `io.output` cannot create a file, a file outside of the config root is reported, and an endless loop aborts with the deadline.
* `PreviewScriptShimTests.swift`: the shim parses `--set <alias> <prop>=<value>` with several pairs, with a value that contains a space, with a value that contains an `=`, it parses the `-m --set` form the same way, and it rejects a command it does not handle.
* `SketchyBarQueryParserTests.swift`: the tolerant parser reads the query reply, survives a value that holds a backslash, and detects the `"[!] …"` error prefix.

The fixtures are the existing parser fixtures. The bridge and shim tests need no SketchyBar and no daemon. The Lua tests use their own fixtures under `Tests/SketchyBarStudioTests/Fixtures/`, one directory per case, and they need no SketchyBar and no daemon either. The test of the real config of the user is skipped when the config is not on the machine.

## Golden-image tests

`BarRenderGoldenTests.swift` renders a fixed config and compares the result with a stored PNG. The render uses a **fixed small virtual display of 480 x 25 points at the fixed scale of 2.0**, so the PNG is 960 x 50 pixels and is deterministic across machines. A rendered bar at the width of a real display would be about 3024 pixels wide, which is neither small nor stable.

The comparison uses a per-pixel tolerance of zero (exact match) for the text and the shapes, so a change in a glyph shows up.

The golden test is **not skipped for the font**: the config of the golden image pins the font of every text (`label.font=Menlo:Bold:14`) and its icon carries no text, so the default family of the renderer (`src/font.c:152-158`) never reaches the pixels of this fixture. The test therefore runs on every machine, and the pixels of the fixture do not depend on the fonts of the machine. An earlier version of this file asked for a skip when `Hack Nerd Font` was missing; the skip was wrong, because the fixture never uses that family, so the only pixel-exact net of stage 4 never ran.

The render of the preview is in the colour space of the device and the golden file is in sRGB, so the test converts the render into sRGB once and compares the two sRGB images. The golden file is written from that same converted image, so both sides of the comparison are in sRGB.

The expected PNG is regenerated per macOS major version, and the macOS version is part of the test file name, because the text rasterization differs between macOS releases.

The golden files are regenerated deliberately, never silently. A golden file that changes in a diff is a review item, not a merge detail. Regenerate it on purpose and say so in the commit message. The test never writes the file of the tree: `SKETCHYBAR_STUDIO_GOLDEN=write` writes the file to a temporary directory and prints that path, so the file of the tree is only replaced on purpose.

## The differential test against the installed binary

`BarRenderDifferentialTests.swift` runs the real `sketchybar --query <item>` against the installed daemon and compares the `bounding_rects` with the rectangles of the vendored renderer. The `bounding_rects` block is the computed layout: the origin and the size of the item per display (`src/bar_item.c:1080-1094`). That makes it the ground truth for the layout. Those values are in **points**, so the comparison is in points, and the criterion is a match within one point.

The fixture config is `Tests/SketchyBarStudioTests/Fixtures/differential.sketchybarrc`. It is a config of the app's own directory, not a user config.

Rules for this test:

* It is **read-only**. It never calls `--set`, and it never changes the live bar.
* The daemon must already be running. The test is skipped when the daemon is not running, and it never fails the build because the daemon is missing. Skip it when `sketchybar --query bar` fails.
* The reply is **close to valid JSON but not always valid JSON**. Tab indent is legal JSON whitespace, `"on"` / `"off"` are quoted strings (`src/misc/helpers.h:79-81`) and parse fine, and there are no trailing commas before the closing braces. The two real breakers are `escape_string` (`src/misc/helpers.h:83-103`), which escapes `"` and newline but **not** the backslash, so a value holding a backslash emits an invalid escape, and the error path, which returns `"[!] …"` (`src/message.c:512`, `src/message.c:529`) and is not JSON at all. The parser has to be tolerant of both, and it has to detect the `"[!]"` error prefix.
* The comparison is per alias, not just a count, so a wrong item order is caught.

The optional differential against a captured screenshot of the real bar needs Screen Recording permission. Screen capture has been **blocked on this machine**, so that test is to be treated as unavailable. The `--query` differential is the replacement.

## Parser fuzzing

`SbarLuaParserTests.swift` gains fuzz-style cases: truncated tables, unbalanced braces, comments inside tables, long strings, and a value that is an expression. The parser must not crash and must not loop (the existing parser already bounds its depth at 32, `Services/LuaTableParser.swift:313`).

## Safety tests

* **No writes to the user's config.** A test renders a config and then checks that no file under the config root changed, and that nothing was written under `backups/`.
* **No live-bar mutation without consent.** With the live-update mode `Never`, a full render-with-scripts cycle leaves the live bar unchanged. Checkable with `sketchybar --query <item>` before and after.

They are the last line of defence for the two things the feature must never do: write to the user's config, and change the live bar without consent.

The **no writes** test extends the existing suite: `Tests/SketchyBarStudioTests/` already has `FileSafetyTests.swift`, `FilesystemSafetyTests.swift` and `StoreDraftSafetyTests.swift`, and the new case belongs with them rather than in a new file. The **no live-bar mutation** test is the only one that goes into `PreviewIsolationTests.swift`.

The live-bar test needs a running daemon. It is skipped when `sketchybar --query bar` fails.

## Fakes and fixtures

* A fixture config directory that holds a Lua config, a shell config and an `sbar.default({...})` block, used by the bridge tests and by the golden tests.
* One fixture directory per case of the Lua path, under `Tests/SketchyBarStudioTests/Fixtures/`, each with its own `sketchybarrc` and `init.lua`: the sandbox, the endless loop, the generated names, the shared counter of the names, an unsupported type, the text of a number and the last argument of an add.
* The differential fixture config `Tests/SketchyBarStudioTests/Fixtures/differential.sketchybarrc`, used by the differential test.
* A fake `sketchybar` on `PATH` for the shim tests: a script that records what it was called with, so the tests can assert that the real binary was never invoked.
* A stub daemon for the query parser tests: a saved `--query` reply with a value that holds a backslash, and a saved `"[!] …"` error reply, so the parser is tested without a running daemon.

## What each stage has to add

The per-stage list is in the stage file itself. In short: [Stage 3](phase-3-config-bridge.md) adds the bridge unit tests, [Stage 4](phase-4-layout-and-render.md) adds the first golden test, [Stage 6](phase-6-live-values.md) adds the shim unit tests, the isolation test and the live-value soak test, [Stage 7](phase-7-live-update-mode.md) adds the mode and the snapshot/restore round trip, and [Stage 8](phase-8-exactness-and-diff.md) adds the differential test and the query parser tests.
