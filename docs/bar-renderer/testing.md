# Test strategy

This file holds the strategy that every stage of the bar renderer shares. The per-stage test requirements stay in the stage files; this file says what the tests are for, what they need, and how they are run.

Run the suite with `swift test` from the repository root. A stage is done when its own tests pass, the whole suite passes, and master is green.

## Unit tests

* `PreviewConfigBridgeTests.swift`: the bridge maps key paths to properties, applies the bar defaults, handles several items per file, and never writes.
* `PreviewScriptShimTests.swift`: the shim parses `--set <alias> <prop>=<value>` with several pairs, with a value that contains a space, with a value that contains an `=`, and it rejects a command it does not handle.
* `SketchyBarQueryParserTests.swift`: the tolerant parser reads the query reply with tab indent, `"on"` / `"off"` and trailing commas.

The fixtures are the existing parser fixtures. The bridge and shim tests need no SketchyBar and no daemon.

## Golden-image tests

`BarRenderGoldenTests.swift` renders fixed configs and compares the result with a stored PNG. The images are small (a few hundred pixels wide) and are compared with a per-pixel tolerance of zero for the text and the shapes, so a change in a glyph shows up. The golden files are regenerated deliberately, never silently.

A golden file that changes in a diff is a review item, not a merge detail. Regenerate it on purpose and say so in the commit message.

## The differential test against the installed binary

`BarRenderDifferentialTests.swift` runs the real `sketchybar --query <item>` against the installed daemon and compares the `bounding_rects` with the rectangles of the vendored renderer. The `bounding_rects` block is the computed layout: the origin and the size of the item per display (`src/bar_item.c:1080-1094`). That makes it the ground truth for the layout.

Rules for this test:

* It is **read-only**. It never calls `--set`, and it never changes the live bar.
* The daemon must already be running. The test is skipped when the daemon is not running, and it never fails the build because the daemon is missing. Skip it when `sketchybar --query bar` fails.
* The reply is **JSON-like but not valid JSON**: tab indent, `"on"` / `"off"` instead of booleans, and trailing commas before the closing braces. The parser has to be tolerant of all three.
* The comparison is per alias, not just a count, so a wrong item order is caught.

The optional differential against a captured screenshot of the real bar needs Screen Recording permission. Screen capture has been **blocked on this machine**, so that test is to be treated as unavailable. The `--query` differential is the replacement.

## Parser fuzzing

`SbarLuaParserTests.swift` gains fuzz-style cases: truncated tables, unbalanced braces, comments inside tables, long strings, and a value that is an expression. The parser must not crash and must not loop (the existing parser already bounds its depth at 32, `Services/LuaTableParser.swift:313`).

## Safety tests

* **No writes to the user's config.** A test renders a config and then checks that no file under the config root changed, and that nothing was written under `backups/`.
* **No live-bar mutation without consent.** With the live-update mode `Never`, a full render-with-scripts cycle leaves the live bar unchanged. Checkable with `sketchybar --query <item>` before and after.

Both tests live in `PreviewIsolationTests.swift`. They are the last line of defence for the two things the feature must never do: write to the user's config, and change the live bar without consent.

## Fakes and fixtures

* A fixture config directory that holds a Lua config, a shell config and an `sbar.default({...})` block, used by the bridge tests and by the golden tests.
* A fake `sketchybar` on `PATH` for the shim tests: a script that records what it was called with, so the tests can assert that the real binary was never invoked.
* A stub daemon for the query parser tests: a saved `--query` reply with tab indent, `"on"` / `"off"` and trailing commas, so the parser is tested without a running daemon.

## What each stage has to add

The per-stage list is in the stage file itself. In short: [Stage 3](phase-3-config-bridge.md) adds the bridge unit tests, [Stage 4](phase-4-layout-and-render.md) adds the first golden test, [Stage 6](phase-6-live-values.md) adds the shim unit tests and the isolation test, [Stage 7](phase-7-live-update-mode.md) adds the mode and the snapshot/restore round trip, and [Stage 8](phase-8-exactness-and-diff.md) adds the differential test and the query parser tests.
