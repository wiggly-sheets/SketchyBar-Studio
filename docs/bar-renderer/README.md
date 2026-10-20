# Bar Renderer — stage documents

Status: **Approved design. NOT STARTED.**
Date: 2026-10-20
Owner: repository owner (sole contributor)
Audience: orchestrating agents and coding agents picking this work up.

SketchyBar Studio will render a SketchyBar bar inside the app, exactly as SketchyBar itself would draw it, for any config or profile in the library, not only the live one. The renderer is a vendored subset of SketchyBar's own C code, compiled into the app as a SwiftPM C target and driven headlessly: it lays items out and paints them into a `CGBitmapContext`, so no window server, no screen recording permission and no running SketchyBar daemon are required. The app's existing SbarLua parser is the config bridge: it reads the Lua of a config into item aliases and qualified key paths, and the app hands the equivalent property assignments to the vendored SketchyBar, so no Lua interpreter and no SbarLua are needed in the app. Item scripts can be executed inside the preview so the bar shows live values; a `sketchybar` shim placed first on `PATH` captures the `--set` calls those scripts make, so a preview can never touch the user's live bar. Pushing a draft into the running SketchyBar becomes an opt-in live-update mode (`Never`, `On Apply`, `While Editing`) with an explicit Restore. Vendoring SketchyBar's GPL-3.0 code forces the whole app to GPL-3.0; the owner accepted that.

Reference implementation: `/Users/Zeb/Developer/SketchyBar`, checkout `v2.24.0-50-gf23f4f4`. The installed `sketchybar` 2.24.1 is the same wiggly-sheets fork. Every claim about SketchyBar behaviour in these documents cites `file:line` in that checkout unless it is marked UNVERIFIED. The full citation list lives in [reference.md](reference.md).

## Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | Render a bar in the app from any config or profile in the library, not only the live one. | The live config is one of many; the editor is unusable for the others without this. It also makes the renderer testable against configs the user does not run. |
| D2 | The in-app render shows live values, with item scripts executed. | A preview with hard-coded labels does not answer "what will my bar look like". Executing the scripts is the only way to get the real values. |
| D3 | The render must be exact, pixel for pixel. This selects vendoring SketchyBar's C code. | See [Why the plan vendors SketchyBar's C](#why-the-plan-vendors-sketchybars-c). Exactness rules out a Swift re-implementation. |
| D4 | "Show on the real bar" becomes a user-configurable live-update mode with three settings (`Never`, `On Apply`, `While Editing`) plus an explicit Restore. | Pushing to the real bar is a side effect on the user's running system. It must be opt-in, granular, and reversible. |
| D5 | The project may switch to GPL-3.0. The owner is the only contributor and wants fully FOSS. | Vendoring SketchyBar's GPL-3.0 code is only possible if the app carries the same licence. The owner accepted this. |
| D6 | Nothing is implemented yet. These documents are the starting point. | No code exists for the renderer. The stages are the contract for the first agent that starts. |

## Why the plan vendors SketchyBar's C

* **Reimplementing the layout in Swift** (roughly 800-1300 lines): the result would be "visually equivalent", not exact, and it would miss defaults inheritance, exotic item types, `q`/`e` positions, dynamic width and `scroll_texts`.
* **Running a second SketchyBar process and screen-capturing it**: two blockers — the compiled SbarLua module at `~/.local/share/sketchybar_lua/sketchybar.so` hard-codes the Mach bootstrap name `git.felix.sketchybar` (verified with `strings`), and a SketchyBar bar is inherently full-display-width (`src/bar.c:437-494`), so inside an app panel it becomes an unreadable ~7pt strip.
* **Capturing the user's real bar** — rejected as the primary path, kept as a feature: it needs Screen Recording permission, and `SLSCaptureWindowsContentsToRectWithOptions` exists in SketchyBar at `src/window.c:347-378`; screen capture has been blocked on this machine, so that test is treated as unavailable ([testing.md](testing.md)).
* **Linking a vendored SketchyBar into an MIT app**: GPL-3.0 covered linking into an MIT app would force the whole app to GPLv3; that blocker is gone under D5. "SketchyBar" as a product name is a trademark risk, not a GPL risk: GPLv3 §7(e) carves trademarks out of the licence (`LICENSE.md:379-380`), so using the name descriptively to talk about the file format is fine. SbarLua is **not** vendored; its licence could not be determined.
* The live-update mode of D4 is **retained as an optional feature**, and is [Stage 7](phase-7-live-update-mode.md).

## Scope

### In scope

* A vendored, headless subset of SketchyBar 2.24 that lays out and paints a bar into a bitmap.
* A config bridge that turns the app's parsed SbarLua (and shell) config into SketchyBar property assignments, including `sbar.default({...})` and `sketchybar --default k=v`.
* Live item values in the preview, produced by running the item scripts with a `PATH` shim that captures `--set` calls.
* A preview pane in the detail view with an Edit / Preview toggle, a profile picker and a scaled-to-fit / 1:1 display control.
* A live-update setting (`Never` / `On Apply` / `While Editing`) with an explicit Restore, and a snapshot of the live bar before anything is pushed.
* A differential test against the installed `sketchybar --query <item>` output, and golden-image tests of the rendered bar.

### Out of scope

* Re-implementing SketchyBar behaviour in Swift. The C code is the renderer.
* Vendoring SbarLua or any Lua interpreter.
* Popups as interactive windows. SketchyBar draws popups in separate windows (`src/bar.c:33-80`); the preview renders the bar only. A popup may be drawn into a second offscreen bitmap later.
* Window-server-backed content in the preview: `alias` items (a captured window image), `space` items, the front-app icon and `media.artwork` cannot be produced without the window server. These render as a placeholder with the same geometry, and the preview says so.
* Mouse interaction with the preview.
* Any change to the user's config files. The renderer reads the config and the drafts in memory; it never writes.
* System-wide theming, app injection or anything that changes other macOS apps. This stays inside the app, per `AGENTS.md`.

## Stage index

| Stage | File | One-line goal | Depends on | Size |
| --- | --- | --- | --- | --- |
| 0 | [phase-0-license.md](phase-0-license.md) | Switch the project to GPL-3.0 | none | S |
| 1 | [phase-1-vendor-core.md](phase-1-vendor-core.md) | Vendor the SketchyBar subset as a SwiftPM C target that compiles and links | 0 | L |
| 2 | [phase-2-headless-core.md](phase-2-headless-core.md) | Headless item tree and the C API exposed to Swift | 1 | M |
| 3 | [phase-3-config-bridge.md](phase-3-config-bridge.md) | The app's parse becomes SketchyBar property assignments | 2 | M |
| 4 | [phase-4-layout-and-render.md](phase-4-layout-and-render.md) | Layout and offscreen render to a `CGImage` | 3 | L |
| 5 | [phase-5-preview-pane.md](phase-5-preview-pane.md) | The in-app preview pane, profile picker and scaling | 4 | M |
| 6 | [phase-6-live-values.md](phase-6-live-values.md) | Item scripts run inside the preview through the `PATH` shim | 5 | M |
| 7 | [phase-7-live-update-mode.md](phase-7-live-update-mode.md) | The user-configurable live-update mode and Restore | 5 | M |
| 8 | [phase-8-exactness-and-diff.md](phase-8-exactness-and-diff.md) | Golden images and the differential test against `sketchybar --query` | 6 | L |
| 9 | [phase-9-docs-and-release.md](phase-9-docs-and-release.md) | README claims, CHANGELOG, release checklist | 8 | S |

The original plan had nine phases, and its Phase 1 was an XL task. It is split here into Stage 1 (vendor the subset, get it to compile and link) and Stage 2 (the headless item tree and the C API). Every other phase is renumbered to match the file names above. Stage 7 does not depend on Stage 6: it only needs Stage 5. Stage 8 needs Stage 6, because the differential test checks the item rectangles that live values change.

## The preview scale (confirmed by the owner on 2026-10-20)

The in-app preview shows the rendered bar **scaled to fit the panel with one uniform scale**, so the real menu-bar aspect ratio survives: the bar is display-width wide and bar-height tall, and it is never re-laid-out or distorted to the panel's shape. A **1:1 toggle** shows the bar at its true pixel size; at 1:1 the bar overflows the panel and the pane scrolls horizontally. The render uses the **target display's real width**, so the proportions are right, and the width can be overridden. [Stage 5](phase-5-preview-pane.md) implements it.

## Module and file table

```
Sources/CSketchyBar/                          C target: vendored SketchyBar subset
  include/sketchybar_preview.h                the only public C API (Stage 2)
  src/                                        vendored files, unmodified except where
                                               the stage documents say they are patched
  shim/sketchybar_preview_display.c            virtual display provider
  shim/sketchybar_preview_window.c            in-memory window records (replaces window.c)
  shim/sketchybar_preview_surface.c            bitmap surface that returns a CGImage
  shim/sketchybar_preview_shim.c               no-op event source
  shim/sketchybar_preview_fork.c               fork_exec with a preview environment
  LICENSE.md                                   the upstream licence, kept with the files
  MODIFICATIONS.md                             every patch this project makes
  UPSTREAM.md                                  the upstream commit that was vendored

Sources/SketchyBarStudio/Models/
  BarRenderModels.swift                       BarRenderRequest, BarRenderResult, LiveUpdateMode
  BarRenderItemModel.swift                    the item tree the preview renders

Sources/SketchyBarStudio/Services/
  PreviewConfigBridge.swift                   parsed config -> SketchyBar property assignments
  BarRendererService.swift                    drives the C target, returns a CGImage
  PreviewScriptRunner.swift                   runs item scripts, enforces timeout and kill
  PreviewScriptShim.swift                     writes the shim script, reads the sink
  LiveBarService.swift                        snapshot, push and restore of the live bar
  SketchyBarQueryParser.swift                 tolerant parser for the --query reply

Sources/SketchyBarStudio/Support/
  SketchyBarPreviewC.swift                    thin Swift wrapper over the C API

Sources/SketchyBarStudio/Views/
  BarRenderView.swift                         the preview pane (image, 1:1 toggle, warnings)
  BarRenderProfilePicker.swift                picks the config or profile to render
  DetailView.swift                            hosts the Edit / Preview toggle (edited)
  SettingsView.swift                          hosts the live-update mode setting (edited)

Tests/SketchyBarStudioTests/
  PreviewConfigBridgeTests.swift              unit tests for the bridge
  PreviewScriptShimTests.swift                unit tests for the shim
  SketchyBarQueryParserTests.swift            unit tests for the tolerant query parser
  BarRenderGoldenTests.swift                  golden-image tests of the rendered bar
  BarRenderDifferentialTests.swift            compares against sketchybar --query
  PreviewIsolationTests.swift                 no config writes, no live-bar mutation
```

Public API sketch of the Swift side:

```swift
/// A request to render one bar.
struct BarRenderRequest {
    /// The config or profile to render.
    let source: BarRenderSource
    /// The item aliases in draw order.
    let items: [BarRenderItem]
    /// The bar level properties, including the defaults of the bar.
    let bar: [String: String]
    /// Values captured from the item scripts, keyed by alias.
    let scriptValues: [String: [String: String]]
}

/// The result of a render.
struct BarRenderResult {
    let image: CGImage
    let pixelSize: CGSize
    /// The origin and size of every item, in pixels.
    let itemRects: [String: CGRect]
    /// Messages from the vendored code and from the script shim.
    let warnings: [String]
}

/// Renders a bar through the vendored SketchyBar subset.
enum BarRenderer {
    static func render(_ request: BarRenderRequest) throws -> BarRenderResult
}

/// How the app may change the user's live bar.
enum LiveUpdateMode: String, CaseIterable {
    case never
    case onApply
    case whileEditing
}
```

Data flow:

```
config files on disk (+ in-memory drafts)
        |
        v
app parsers  (LuaTableParser / SbarLuaItemParser / ShellConfigScanner)
        |  aliases + qualified key paths
        v
config bridge  (PreviewConfigBridge)
        |  property assignments
        v
vendored SketchyBar subset  (items, defaults inheritance, layout, CoreGraphics paint)
        |
        |  CGImage
        v
SwiftUI preview pane  (scaled to fit, or 1:1)

item scripts --(fork_exec, PATH shim)--> sink file --> property assignments --> re-render
```

## How to work on this

**Branches and worktrees.**

* One branch per stage: `feat/bar-renderer/stage-N`.
* Each stage is developed in its **own git worktree**, under the temp opencode directory (`/private/var/folders/.../opencode`), not in the main checkout. Parallel agents contended for the main checkout before.
* Merge into master with `git merge --no-ff`, so each stage is a merge commit.
* Keep master green after every merge: `swift build`, `swift test`, `./script/build_and_run.sh --package`.
* Never push unless the owner says so.
* Update `CHANGELOG.md` in the same stage as the change, under `## [Unreleased]`.

**Roles.**

* `coder` implements the stage.
* `reviewer` reviews read-only. It does not edit files.
* `scribe` owns these documents and the README / CHANGELOG.

**AGENTS.md rules that bind this work.**

* Native macOS controls only: `NSOpenPanel`, `ColorPicker`, the font panel, SwiftUI settings, forms and split views. No custom-drawn controls.
* App-only theming. Nothing in this feature may change Notes, Safari, Finder or any other macOS app, and nothing may inject into another process.
* SketchyBar and SbarLua syntax is the source of truth for option names and valid values. The renderer follows the source, not the app's convenience.
* Never run destructive git commands and never delete user config files.
* Never modify the user's config files without a backup, and keep the mirrored `backups/` behaviour intact.
* No new external SwiftPM dependencies without a clear benefit and handled CI/release impact. The vendored C code is not an external dependency; it is in-tree source under the same licence.
* Keep edits scoped. A stage touches its own files and does not refactor the rest of the app.
* Run `swift build` after code changes, and `./script/build_and_run.sh --package` after packaging or bundle changes. Mention any command that could not run.
* Keep the final notes concise, with the touched files and the verification result.

**Documentation that must stay in step.** `README.md`, `CHANGELOG.md`, `docs/RELEASE_CHECKLIST.md`, these documents, and `AGENTS.md` if the repo layout changes (the new `Sources/CSketchyBar` target has to be added to the repo layout section).

## Licensing

The repository is MIT today. Vendoring SketchyBar's GPL-3.0 code means the whole app must be GPL-3.0. The owner accepted that under D5. Stage 0 makes the switch before any GPL code lands. The full requirements — corresponding source, notices, declaration of modification, installation information, attribution of both upstream projects, and the SbarLua exclusion — are in [phase-0-license.md](phase-0-license.md).

## Definition of done

The feature is done when all of the following hold.

1. The app renders a bar from any config or profile in the library, not only the live one, from the detail view.
2. The render is produced by the vendored SketchyBar code, not by a Swift re-implementation.
3. The preview shows live values: the item scripts run and their `--set` calls reach the preview.
4. The live bar is provably unchanged by a preview cycle, in every live-update mode that is not `While Editing` and not an explicit push.
5. The live-update mode has the three settings and an explicit Restore, and Restore returns the live bar to the state it had before the first push.
6. The item rectangles of the renderer match `sketchybar --query <item>` within one pixel for the fixture configs.
7. `swift build`, `swift test` and `./script/build_and_run.sh --package` pass, and the packaged app runs.
8. The repository is GPL-3.0, the vendored code keeps its notices, the modifications are declared, and the release notes make the source offer.
9. The README, the CHANGELOG and the release checklist describe the shipped behaviour.
10. The known limits are stated in the app and in the README: no popups, no window-server content (`alias`, `space`, front-app icon, `media.artwork`), no interaction.

## Top risks

| Risk | Impact | Mitigation | Owner |
| --- | --- | --- | --- |
| The vendored subset does not compile after the window-server files are stripped. | Stage 1 fails; the whole plan stops. | Stage 1 is an explicit gate with its own fallback (static library built by a script). The compile happens in Stage 1, before any other stage. | [Stage 1](phase-1-vendor-core.md) |
| `src/symbol.m` (Objective-C) does not fit a SwiftPM C target. | SF Symbols cannot be drawn, so the render is not exact. | Verify in Stage 1, first. Fallback: build the subset as a static library and link it with `.unsafeFlags`. | [Stage 1](phase-1-vendor-core.md) |
| Private frameworks leak back into the link. | The app would need the same private entitlements as SketchyBar, and the bundle would break. | Acceptance criterion in Stage 1: `otool -L` shows no SkyLight, DisplayServices or MediaRemote. | [Stage 1](phase-1-vendor-core.md) |
| The app is MIT today and the vendored code is GPL-3.0. | The app cannot ship as MIT. | Stage 0 switches the licence before any GPL code lands. The decision is already taken by the owner. | [Stage 0](phase-0-license.md) |
| The renderer is not exact for the item types the app cannot produce. | The user sees a preview that differs from the real bar. | The window-server limits are stated in the app and in the README, and the differential test only claims the geometry it can check. | [Stage 8](phase-8-exactness-and-diff.md) |
| A preview script reaches the live bar. | The user's real bar changes without consent. | The PATH shim, the patched child environment, the "no live-bar mutation" test, and the rule that the shim never forwards an unknown command. A script that calls the binary by absolute path is a known limit and is stated. | [Stage 6](phase-6-live-values.md) |
| `--set` on the server re-splits a value on spaces, so a label with a space cannot be pushed. | Live values with spaces are wrong, or a push fails. | Open question 1. The transport preserves spaces, so the risk is in the per-property parse. Confirm before Stage 6 and Stage 7 rely on it. | [Stage 6](phase-6-live-values.md) |
| The preview leaks memory or file descriptors over a long session. | The app slows down or crashes. | The preview is created and destroyed per render; the golden tests and the live-value loop are run in a soak test. | [Stage 2](phase-2-headless-core.md) |
| The vendored code drifts from the SketchyBar release the user runs. | The preview matches an older SketchyBar. | Record the upstream commit in `Sources/CSketchyBar/UPSTREAM.md` and show it in the About panel or the release notes. | [Stage 1](phase-1-vendor-core.md), [Stage 9](phase-9-docs-and-release.md) |
| The renderer pushes the wrong item order, so the preview is misleading. | The user trusts a wrong preview. | The differential test compares the rectangles per alias, not just the count. | [Stage 8](phase-8-exactness-and-diff.md) |

## Open questions

Every item below is **UNVERIFIED** and must be confirmed against the source or by experiment before the stage that depends on it starts. The full text, with the citations, is in [reference.md](reference.md).

1. Does the SketchyBar `--set` server re-split a `property=value` argument on spaces? (Stage 6, Stage 7)
2. Does the vendored subset compile cleanly after the private-framework files are removed? (Stage 1)
3. What exactly does `sbar.default({...})` do when a script overrides it? (Stage 3, Stage 8)
4. Do the `Highlight` / `icon` image-versus-text semantics match the fork's man page? (Stage 3, Stage 8)
5. What happens to `src/display_nsscreen.m` in the vendored subset? (Stage 1)
6. How does the fork's `space` item behave in a preview? (Stage 4)
7. How long does a typical item script take, and what timeout is right? (Stage 6)

The `icon` prefix semantics are a separate question to confirm, written up in [reference.md](reference.md#the-icon-prefix-semantics--a-question-to-confirm). Do not change `SketchyBarIcon` on the strength of that note.

## Start here

Read this file, then read the stage file you were given, then execute that stage. Nothing else needs to be read first.
