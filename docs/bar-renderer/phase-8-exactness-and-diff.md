# Stage 8 — Exactness hardening and differential testing

**Dependencies satisfied.** The four platform features that landed before this stage are: shell parity (`ShellDiagnosticService`, shell clone, shell configs on the same diagnostic and preview surface as Lua), editor highlighting (`SourceSyntaxHighlighter` tokeniser plus native find bar), bar theme switching (27 palettes, three detection patterns — pointer file, Lua variable plus computed require, literal require — preview, byte-identical revert via `UserDefaults`), and the plugin/Setup store (14 verified MIT entries, README preview, staged setup install, dependency policy, manifest uninstall). Stage 8 builds on all of them: the differential test compares the rectangles of every item type the shell and Lua paths can reach, the highlighter colours the code preview the editor writes, the theme switching keeps the previewed bar in the palette the user applied, and the store installs the setups and plugins the fixtures use.

## Goal

The rendered bar matches the real SketchyBar. The item rectangles of the vendored renderer are compared against the layout the installed daemon reports, and every difference is fixed.

## Depends on

[Stage 6](phase-6-live-values.md) must be merged. The differential test compares the rectangles of a rendered bar, and the live values change them.

## In scope / Out of scope

**In scope.** The differential test, the tolerant query parser, the fixes it finds, and the known limits in the preview.

**Out of scope.** The preview pane ([Stage 5](phase-5-preview-pane.md)), the live-update mode ([Stage 7](phase-7-live-update-mode.md)), and the release notes ([Stage 9](phase-9-docs-and-release.md)).

## Tasks

1. Write the differential test: for the fixture config, compare the item rectangles from the vendored renderer against the `bounding_rects` of the installed `sketchybar --query <item>`. The `bounding_rects` block is the computed layout, with the origin and the size per display (`src/bar_item.c:1080-1094`). Those values are **window frames in points**, so the comparison is in points.
2. Write a tolerant parser for the query reply, because the reply is close to valid JSON but is not always valid JSON. Tab indent is legal JSON whitespace, `"on"` / `"off"` are quoted strings (`src/misc/helpers.h:79-81`) and parse fine, and there are no trailing commas before the closing braces. The real breakers are the backslash, which `escape_string` does not escape (`src/misc/helpers.h:83-103`), so a value holding a backslash emits an invalid escape, and the error path, which returns `"[!] …"` (`src/message.c:512`, `src/message.c:529`) and is not JSON at all. The parser has to survive both, and it has to detect the `"[!]"` error prefix.
3. Fix every difference the differential test finds, one item type at a time.
4. Check the defaults inheritance, the `align` behaviour, `max_chars`, `scroll_texts`, the group background and the symbol size model.
5. Add the known limits to the preview as warnings: `alias`, `space`, front-app icon and `media.artwork` cannot be produced without the window server.

The semantics that decide each of these are listed in [reference.md](reference.md#item-semantics-that-matter-for-exactness). The parser and the golden-image details are in [testing.md](testing.md).

## Files

**Create.** `Tests/SketchyBarStudioTests/BarRenderDifferentialTests.swift`, `Tests/SketchyBarStudioTests/Fixtures/differential.sketchybarrc` (the fixture config the differential test renders), `Sources/SketchyBarStudio/Services/SketchyBarQueryParser.swift`, `Tests/SketchyBarStudioTests/SketchyBarQueryParserTests.swift`.

**Modify.** `Sources/CSketchyBar/**` (the fixes), `Sources/CSketchyBar/MODIFICATIONS.md`, `Sources/SketchyBarStudio/Views/BarRenderView.swift` (the limit warnings).

**Do not touch.** `Sources/SketchyBarStudio/Stores/**`, `dist/`, and any file under a user config root.

## Acceptance criteria

* For the fixture config, every item rectangle matches the `bounding_rects` of the installed daemon within one point.
* The query parser reads a real `--query` reply and a reply whose value contains a backslash, and it detects the `"[!] …"` error prefix instead of trying to parse it as JSON.
* The differential test is skipped, not failed, when the daemon is not running.
* The differential test never calls `--set`; it only issues `--query`.
* The preview shows a warning for `alias`, `space`, the front-app icon and `media.artwork` items, and for popups.
* The defaults inheritance, the `align` behaviour, `max_chars`, `scroll_texts`, the group background and the symbol size model each have a test that pins the result.

## Tests

The differential test itself, plus the golden-image tests. The differential test is read-only, needs the daemon running, and is skipped when the daemon is missing; it never fails the build because the daemon is missing. The optional differential against a captured screenshot of the real bar is unavailable on this machine; see [testing.md](testing.md#the-differential-test-against-the-installed-binary).

## Risks and unknowns

* The renderer is not exact for the item types the app cannot produce. The user sees a preview that differs from the real bar. Mitigation: the window-server limits are stated in the app and in the README, and the differential test only claims the geometry it can check.
* The renderer pushes the wrong item order, so the preview is misleading. The user trusts a wrong preview. Mitigation: the differential test compares the rectangles per alias, not just the count.
* The vendored code drifts from the SketchyBar release the user runs. The preview matches an older SketchyBar. Mitigation: the upstream commit is recorded in `Sources/CSketchyBar/UPSTREAM.md` and shown in the About panel or the release notes.
* The installed daemon and the vendored code may be different versions. The differential test then reports differences that are not renderer bugs; read the version before treating a difference as a defect.

## Done when

Every item rectangle of the fixture config matches the daemon within one point, the tolerant parser is covered by unit tests, the known limits are visible in the preview, the golden and differential tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
