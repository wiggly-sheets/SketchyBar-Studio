# Bar Renderer — stage documents

Status: **Approved design. Stages 0-7 and Stage 3d merged; Stage 8 (exactness and the differential test) is next.**
Date: 2026-10-21
Owner: repository owner (sole contributor)
Audience: orchestrating agents and coding agents picking this work up.

SketchyBar Studio will render a SketchyBar bar inside the app, exactly as SketchyBar itself would draw it, for any config or profile in the library, not only the live one. The renderer is a vendored subset of SketchyBar's own C code, compiled into the app as a SwiftPM C target and driven headlessly: it lays items out and paints them into a `CGBitmapContext`, so no window server, no screen recording permission and no running SketchyBar daemon are required. The app's existing SbarLua parser is the config bridge: it reads the Lua of a config into item aliases and qualified key paths, and the app hands the equivalent property assignments to the vendored SketchyBar. SbarLua itself is not vendored; a vendored Lua interpreter ([Stage 3b](phase-3-config-bridge.md)) resolves the expressions of a config, so a colour, a font or a padding that a config builds with an expression reaches the preview as the value of the config and not as the default of SketchyBar. Item scripts can be executed inside the preview so the bar shows live values; a `sketchybar` shim placed first on `PATH` captures the `--set` calls those scripts make, so a preview can never touch the user's live bar. Pushing a draft into the running SketchyBar becomes an opt-in live-update mode (`Never`, `On Apply`, `While Editing`) with an explicit Restore. Vendoring SketchyBar's GPL-3.0 code forces the whole app to GPL-3.0; the owner accepted that.

Reference implementation: `/Users/Zeb/Developer/SketchyBar`, checkout `v2.24.0-50-gf23f4f4`. The installed `sketchybar` 2.24.1 is the same wiggly-sheets fork. Every claim about SketchyBar behaviour in these documents cites `file:line` in that checkout unless it is marked UNVERIFIED. The full citation list lives in [reference.md](reference.md).

## Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | Render a bar in the app from any config or profile in the library, not only the live one. | The live config is one of many; the editor is unusable for the others without this. It also makes the renderer testable against configs the user does not run. |
| D2 | The in-app render shows live values, with item scripts executed. | A preview with hard-coded labels does not answer "what will my bar look like". Executing the scripts is the only way to get the real values. |
| D3 | The render must be exact, pixel for pixel. This selects vendoring SketchyBar's C code. | See [Why the plan vendors SketchyBar's C](#why-the-plan-vendors-sketchybars-c). Exactness rules out a Swift re-implementation. |
| D4 | "Show on the real bar" becomes a user-configurable live-update mode with three settings (`Never`, `On Apply`, `While Editing`) plus an explicit Restore. | Pushing to the real bar is a side effect on the user's running system. It must be opt-in, granular, and reversible. |
| D5 | The project switched to GPL-3.0 (decided by the owner, executed in Stage 0). The owner is the only contributor and wants fully FOSS. | Vendoring SketchyBar's GPL-3.0 code is only possible if the app carries the same licence. The owner accepted this. |
| D6 | The resolved config is shown with the draft of the app applied on top, and the resolution is cached by a disk signature. | The preview ran the config in the Lua interpreter and threw the raw run away, so a draft could not see the value the config really has. Stage 3d keeps the resolved plan and overlays the draft on it, and re-runs the Lua only when a file of the config changes on disk. |
| D7 | The project vendors a Lua interpreter to resolve the expressions of a config (Stage 3b). SbarLua itself is still not vendored. | **Taken by the owner on 2026-10-21**, after the preview of a config that builds its colours, its fonts and its paddings with expressions showed the defaults of SketchyBar instead of the values of the config. The owner asked for an exact rendering and accepted the interpreter route when it was presented. An expression cannot be read without an interpreter, and the interpreter is in-tree source under the same licence. |

## Why the plan vendors SketchyBar's C

* **Reimplementing the layout in Swift** (roughly 800-1300 lines): the result would be "visually equivalent", not exact, and it would miss defaults inheritance, exotic item types, `q`/`e` positions, dynamic width and `scroll_texts`.
* **Running a second SketchyBar process and screen-capturing it**: two blockers — the compiled SbarLua module at `~/.local/share/sketchybar_lua/sketchybar.so` hard-codes the Mach bootstrap name `git.felix.sketchybar` (UNVERIFIED-IN-THIS-CHECKOUT: the string is in the installed module, but the module is not part of the `v2.24.0-50-gf23f4f4` checkout, so confirm it with `strings` before relying on it), and a SketchyBar bar is inherently full-display-width (`src/bar.c:437-494`), so inside an app panel it becomes an unreadable ~7pt strip.
* **Capturing the user's real bar** — rejected as the primary path, kept as a feature: it needs Screen Recording permission, and `SLSCaptureWindowsContentsToRectWithOptions` exists in SketchyBar at `src/window.c:347-378`; screen capture has been blocked on this machine, so that test is treated as unavailable ([testing.md](testing.md)).
* **Linking a vendored SketchyBar into a non-GPL app**: GPL-3.0 covered linking into an MIT app would force the whole app to GPLv3; that blocker is gone under D5, and Stage 0 switched the repository to GPL-3.0. "SketchyBar" as a product name is a trademark risk, not a GPL risk: GPLv3 §7(e) carves trademarks out of the licence (`LICENSE.md:379-380`), so using the name descriptively to talk about the file format is fine. The app already carries the name in its own product name; the owner decided that question on 2026-10-20 — the product name stays "SketchyBar Studio" and the README carries one non-affiliation line — so the question is closed. [Stage 0](phase-0-license.md#trademark-note) records the decision. SbarLua is **not** vendored; its licence could not be determined.
* The live-update mode of D4 is **retained as an optional feature**, and is [Stage 7](phase-7-live-update-mode.md).

## Scope

### In scope

The stages below are the scope. Each stage file states its own in scope and out of scope. In one line each: the vendored headless renderer ([Stage 1](phase-1-vendor-core.md) to [Stage 4](phase-4-layout-and-render.md)), the config bridge ([Stage 3](phase-3-config-bridge.md)), the preview pane ([Stage 5](phase-5-preview-pane.md)), the live values ([Stage 6](phase-6-live-values.md)), the live-update mode ([Stage 7](phase-7-live-update-mode.md)), and the exactness work ([Stage 8](phase-8-exactness-and-diff.md)).

### Out of scope

* Re-implementing SketchyBar behaviour in Swift. The C code is the renderer.
* Vendoring SbarLua. The Lua interpreter of [Stage 3b](phase-3-config-bridge.md) is vendored (see D7), SbarLua itself is not, because its licence could not be determined.
* Popups as interactive windows. SketchyBar draws popups in separate windows (`src/popup.c:375-383`); the preview renders the bar only. A popup may be drawn into a second offscreen bitmap later.
* A value that is built by an expression, such as `colors.red`, needs a Lua interpreter. The parser path cannot read it, so it keeps the value SketchyBar has by default and names the value in its warnings; the Lua path of Stage 3b reads it.
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
| 3b | [phase-3-config-bridge.md](phase-3-config-bridge.md) | The config is resolved with a real Lua interpreter, so the values built by an expression reach the preview | 3 | L |
| 3c | [phase-3-config-bridge.md](phase-3-config-bridge.md) | Every item type of a config reaches the preview, not only the plain items | 3b | M |
| 3d | [phase-3-config-bridge.md](phase-3-config-bridge.md) | The resolved config is shown with the draft of the app applied on top, and the resolution is cached by a disk signature | 3c | M |
| 4 | [phase-4-layout-and-render.md](phase-4-layout-and-render.md) | Layout and offscreen render to a `CGImage` | 3 | L |
| 5 | [phase-5-preview-pane.md](phase-5-preview-pane.md) | The in-app preview pane, profile picker and scaling | 4 | M |
| 6 | [phase-6-live-values.md](phase-6-live-values.md) | The item scripts run inside the preview, isolated from the real bar | 5 | M |
| 7 | [phase-7-live-update-mode.md](phase-7-live-update-mode.md) | The user-configurable live-update mode and Restore, so a push to the running bar stays opt-in and can always be undone | 5 | M |
| 8 | [phase-8-exactness-and-diff.md](phase-8-exactness-and-diff.md) | Golden images and the differential test against `sketchybar --query` | 6 | L |
| 9 | [phase-9-docs-and-release.md](phase-9-docs-and-release.md) | README claims, CHANGELOG, release checklist | 8 | S |

The original plan had nine phases, and its Phase 1 was an XL task. It is split here into Stage 1 (vendor the subset, get it to compile and link) and Stage 2 (the headless item tree and the C API). Every other phase is renumbered to match the file names above. Stage 7 does not depend on Stage 6: it only needs Stage 5. Stage 8 needs Stage 6, because the differential test checks the item rectangles that live values change.

Stages 3b and 3c were added later, and both exist because of the config of the owner: 3b because 141 of the values of that config are built by Lua expressions that no parser can resolve (its fonts, its colours and its paddings among them), and 3c because the resolver of Stage 3b found 36 components that are not plain items and the bridge was dropping them.

Stage 7 exists because the preview and the running bar are two different things: a user who edits a config in Studio wants to see the result in the running SketchyBar, and a user who changed the bar in the running daemon wants to see it in the preview. A push is a side effect on the running system of the user, so it is opt-in (`Never`, `On Apply`, `While Editing`), the automatic modes push only the safe properties of the bar and the settings of the bar need an explicit action, and a snapshot of the live bar on disk makes Restore work after a restart.

## The preview scale (confirmed by the owner on 2026-10-20)

The in-app preview draws the bar at its **true size** and lets the **view** apply **one uniform scale** that fits the pane width. That scale preserves the real menu-bar aspect ratio: display width minus twice the margin, by the bar height. The bar is **never re-laid-out** and **never stretched or distorted** to the pane's shape. A **1:1 toggle** shows the bar at its true point size, so one image pixel lands on one device pixel on a 2× display; at 1:1 the bar overflows the panel and the pane scrolls horizontally. The render uses the **target display's real width in points**, not the main screen's width, so the proportions are right, and the user can override the width. [Stage 5](phase-5-preview-pane.md) implements it.

The layout, the item rectangles and the `bounding_rects` of `sketchybar --query` are in **points**, and the bitmap is rendered at the fixed scale of **2.0** whatever the scale of the display. [Stage 2](phase-2-headless-core.md) and [Stage 4](phase-4-layout-and-render.md) implement it.

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
  preview/sketchybar_preview.c                 the C API and the headless item tree (Stage 2)
  preview/sketchybar_preview_bar.c             the bar manager and the bar domain (Stage 2)
  preview/sketchybar_preview_stubs.c           the symbols of the dropped files (Stage 2)
  preview/sketchybar_preview_test.c            the test-only accessors (Stage 2)
  LICENSE.md                                   the upstream licence, kept with the files
  MODIFICATIONS.md                             every patch this project makes
  UPSTREAM.md                                  the upstream commit that was vendored
Sources/CLua/                                  C target: vendored Lua 5.5.0 interpreter
  include/clua.h                               the only public C API (Stage 3b)
  lua/                                         vendored sources of Lua 5.5.0, unmodified
  clua.c                                       the wrapper: the bounded allocator and the
                                               deadline of the run (Stage 3b)
  LICENSE                                      the upstream licence, kept with the files
  MODIFICATIONS.md                             every change this project makes
  UPSTREAM.md                                  the upstream release that was vendored
```

The `preview/` directory holds the code of the preview itself. It is not
upstream code and not a replacement of a dropped upstream file, so it never
lives in `src/`: the vendor script empties `src/` on every run and would
delete it there.

Every file on the Swift side, with the stage that owns it, is in the **Files** section of that stage file. The new files are `Models/BarRenderModels.swift` and `Models/BarRenderItemModel.swift` (Stage 3), `Services/PreviewConfigBridge.swift` (Stage 3), `Support/SketchyBarPreviewC.swift` (Stage 1), `Services/BarRendererService.swift` and `Views/BarRenderView.swift` and `Views/BarRenderProfilePicker.swift` (Stage 5), `Services/PreviewScriptShim.swift` and `Services/PreviewScriptRunner.swift` (Stage 6), `Services/LiveBarService.swift` (Stage 7), `Services/SketchyBarQueryParser.swift` (Stage 8), and `Support/LuaConfigRunner.swift` and `Support/LuaSketchyBarShim.swift` (Stage 3b). The test files are in the stage that adds them, and the test files that already exist in the repository are listed in [reference.md](reference.md#the-repository-files-this-plan-touches).

Public API sketch of the Swift side. The C API and its contract are in [Stage 2](phase-2-headless-core.md).

```swift
struct BarRenderRequest {
    let source: BarRenderSource
    let items: [BarRenderItem]
    let bar: [String: String]
    /// The default-item properties, applied before the items are added.
    let defaults: [String: String]
    let scriptValues: [String: [String: String]]
}
struct BarRenderResult {
    let image: CGImage
    let pixelSize: CGSize
    /// The origin and size of every item, in points.
    let itemRects: [String: CGRect]
    let warnings: [String]
}
enum BarRenderer {
    static func render(_ request: BarRenderRequest) throws -> BarRenderResult
}
enum LiveUpdateMode: String, CaseIterable { case never, onApply, whileEditing }
```

Data flow:

```
config files (+ in-memory drafts)
  -> app parsers -> config bridge -> vendored SketchyBar subset -> CGImage -> preview pane
  -> vendored Lua interpreter (Stage 3b) -> config bridge -> vendored SketchyBar subset -> CGImage -> preview pane
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

**How a stage actually runs.**

* The orchestrator creates the worktree and the branch before the coder starts:

  ```
  git worktree add /private/var/folders/0j/qfzrfr8928jbh4b0dh9w97qr0000gn/T/opencode/sbs-stage-N -b feat/bar-renderer/stage-N master
  ```

  The exact path is whatever the orchestrator creates; the rule is that it lives under the temp opencode directory and never in the main checkout.
* The orchestrator hands the coder two things: the stage file to read, and the absolute path of the worktree to work in. The coder works only in that worktree.
* The coder commits on the stage branch, and hands the commit range back to the orchestrator.
* The reviewer reviews the commit range read-only.
* The orchestrator runs the post-merge verification — `swift build`, `swift test`, `./script/build_and_run.sh --package` on master — before the next stage starts.
* After the merge, the orchestrator removes the worktree: `git worktree remove <path>`, and `git worktree prune`.
* A stage does not start until the previous stage is merged and master is green.
* The scribe records **deviations** from the plan in the plan itself, so the documents describe what was actually built.

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

The repository is GPL-3.0. Stage 0 switched the licence before any GPL code landed. Vendoring SketchyBar's GPL-3.0 code means the whole app must be GPL-3.0, and the owner accepted that under D5. The full requirements — corresponding source, notices, declaration of modification, installation information, attribution of both upstream projects, and the SbarLua exclusion — are in [phase-0-license.md](phase-0-license.md).

**Trademark decision — taken 2026-10-20 by the owner.** GPLv3 §7(e) withholds trademark rights, so the licence switch settled the COPYING question only, not the name question. Using "SketchyBar" descriptively — for the config format, the config directory, the CLI and the daemon — is fine. The product name stays "SketchyBar Studio", and the README carries one non-affiliation line. The owner owns the wiggly-sheets fork that Stage 1 vendors from, so only upstream Felix Kratz's mark is not the owner's. The owner decides, and the question is closed: no further trademark work is planned. The reasoning and the decision are in [phase-0-license.md](phase-0-license.md#trademark-note).

## Definition of done

The feature is done when all of the following hold.

1. The app renders a bar from any config or profile in the library, not only the live one, from the detail view.
2. The render is produced by the vendored SketchyBar code, not by a Swift re-implementation.
3. The preview shows live values: the item scripts run and their `--set` calls reach the preview.
4. The live bar is provably unchanged by a preview cycle, in every live-update mode that is not `While Editing` and not an explicit push.
5. The live-update mode has the three settings and an explicit Restore, and Restore returns the live bar to the state it had before the first push.
6. The item rectangles of the renderer match `sketchybar --query <item>` within one point for the fixture configs.
7. `swift build`, `swift test` and `./script/build_and_run.sh --package` pass, and the packaged app runs.
8. The repository is GPL-3.0, the vendored code keeps its notices, the modifications are declared, and the release notes make the source offer.
9. The README, the CHANGELOG and the release checklist describe the shipped behaviour.
10. The known limits are stated in the app and in the README: no popups, no window-server content (`alias`, `space`, front-app icon, `media.artwork`), no interaction.

## Must-fix items of Stage 3d

Two items the stage found and fixed. Both are resolved.

| # | Item | Resolution |
| --- | --- | --- |
| F2 | The resolution of a config was re-run on every keystroke of a draft. | The resolved plan is kept in a cache keyed by a disk signature of the config's files. A draft changes the text the app holds and not the text on disk, so a keystroke reuses the resolved config and only puts the draft on top of it. A file that changes on disk is a new signature and is resolved again. A run that fails is kept too, so a config that runs into the deadline of the sandbox does not stop the pane on every keystroke. |
| F3 | A shell config fell back to the parser and said nothing about it. | The fallback now names the reason: a config that has no Lua entrypoint is read by the parser and the pane says that the values are the ones the parser can read. The bridge and the pane use the same words. |

## Top risks

| Risk | Impact | Mitigation | Owner |
| --- | --- | --- | --- |
| The vendored subset does not compile after the window-server files are stripped. | Stage 1 fails; the whole plan stops. | Stage 1 is an explicit gate with its own fallback (static library built by a script). The compile happens in Stage 1, before any other stage. | [Stage 1](phase-1-vendor-core.md) |
| `src/symbol.m` (Objective-C) does not fit a SwiftPM C target. | SF Symbols cannot be drawn, so the render is not exact. | Verify in Stage 1, first. Fallback: build the subset as a static library and link it with `.unsafeFlags`. | [Stage 1](phase-1-vendor-core.md) |
| Private frameworks leak back into the link. | The app would need the same private entitlements as SketchyBar, and the bundle would break. | Acceptance criterion in Stage 1: `otool -L` shows no SkyLight, DisplayServices or MediaRemote. | [Stage 1](phase-1-vendor-core.md) |
| The app was MIT and the vendored code is GPL-3.0. | The app cannot ship as MIT. | Stage 0 switched the licence before any GPL code landed. The decision is already taken by the owner. | [Stage 0](phase-0-license.md) |
| The renderer is not exact for the item types the app cannot produce. | The user sees a preview that differs from the real bar. | The window-server limits are stated in the app and in the README, and the differential test only claims the geometry it can check. | [Stage 8](phase-8-exactness-and-diff.md) |
| A preview script reaches the live bar. | The user's real bar changes without consent. | The PATH shim, the patched child environment, the "no live-bar mutation" test, and the rule that the shim never forwards an unknown command. A script that calls the binary by absolute path is a known limit; the child `PATH` is scrubbed so it cannot reach the real binary, and the preview warns when a script references an absolute `sketchybar` path. | [Stage 6](phase-6-live-values.md) |
| Whether a value with a space survives the per-property parse is **UNVERIFIED**. | Live values with spaces are wrong, or a push fails. | Open question 1. The transport and the `=` split preserve spaces; confirm `bar_item_parse_set_message` and the text parser by experiment before the live-values and live-update stages rely on it. | [Stage 6](phase-6-live-values.md) |
| The preview leaks memory or file descriptors over a long session. | The app slows down or crashes. | The preview is created and destroyed per render; Stage 2 runs a soak test of a thousand create / destroy cycles, and Stage 6 runs a soak test of the live-value loop. | [Stage 2](phase-2-headless-core.md), [Stage 6](phase-6-live-values.md) |
| The vendored code drifts from the SketchyBar release the user runs. | The preview matches an older SketchyBar. | Stage 1 records the upstream commit in `Sources/CSketchyBar/UPSTREAM.md`, and Stage 9 shows it in the About panel or the release notes. | [Stage 1](phase-1-vendor-core.md), [Stage 9](phase-9-docs-and-release.md) |
| The renderer pushes the wrong item order, so the preview is misleading. | The user trusts a wrong preview. | The differential test compares the rectangles per alias, not just the count. | [Stage 8](phase-8-exactness-and-diff.md) |

## Open questions

Every item below is **UNVERIFIED** and must be confirmed against the source or by experiment before the stage that depends on it starts. The full text, with the citations, is in [reference.md](reference.md#open-questions).

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

Status: Stage 7 (the live update mode) is done — this document lands with its merge. The next stage to run is Stage 8 (exactness and the differential test) — see docs/bar-renderer/phase-8-exactness-and-diff.md.
