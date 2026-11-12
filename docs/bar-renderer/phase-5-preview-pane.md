# Stage 5 — The in-app preview pane

**Status: done (2026-10-21).** The preview pane is merged with this stage. The next stage is Stage 6.

## Goal

The user can look at a rendered bar of any config or profile, from the detail view. The rendered bar is scaled to fit the panel with one uniform factor, so the real menu-bar proportions survive, and a 1:1 toggle restores the exact pixel geometry.

## Depends on

[Stage 4](phase-4-layout-and-render.md) must be merged. There has to be a rendered `CGImage` to show.

## In scope / Out of scope

**In scope.** The Edit / Preview toggle, the preview view, the profile picker, the draft in the preview, and the display scale.

**Out of scope.** The live values ([Stage 6](phase-6-live-values.md)), the live-update mode ([Stage 7](phase-7-live-update-mode.md)), and the removal of the existing draft preview affordances.

## Tasks

1. Add an Edit / Preview toggle to `Views/DetailView.swift`.
2. Add `Views/BarRenderView.swift`: shows the rendered `CGImage`, the warnings, and the 1:1 control.
3. Add `Views/BarRenderProfilePicker.swift`: the user picks which config or profile in the library is rendered. The live config is one of the choices, not the only one.
4. Show the current draft, not the file on disk, so the preview matches the code preview.
5. Implement the display scale, as decided below.

### Display scale (confirmed by the owner on 2026-10-20)

A SketchyBar bar is full menu-bar width (display width minus twice the margin, `src/bar.c:437-494`) and bar-height tall. The detail pane is far narrower, so:

* The bar is drawn at its **true size**, and the **view** applies **one uniform scale** that fits the pane width. That scale preserves the real menu-bar aspect ratio: display width minus twice the margin, by the bar height.
* The bar is **never re-laid-out** and **never stretched or distorted** to the pane's shape. The bar is one image, and the view scales that image.
* At **1:1** the bar overflows the pane and the pane **scrolls horizontally**. The user sees the left part of the bar and can scroll to the rest.
* The rendered image is drawn at its true pixel size and scaled by the view, so the pixels are never re-sampled by the renderer.
* The render uses the **target display's real width in points**, not the main screen's width, so the proportions are right. The width can be overridden, and the override is visible in the UI.

### The existing preview

The current preview is `Sources/SketchyBarStudio/Views/BarPreviewView.swift`. It is a draft bar preview for editing: one preview row per **file**, not per item, drawn with SwiftUI. It is useful for reordering and width editing and it stays. The new renderer replaces the *rendering* of the preview; the reordering and width editing affordances of the existing view stay, and the new preview pane is added alongside them. The gap list of the current preview is in [reference.md](reference.md#the-gap-list-of-the-current-preview).

## Files

**Create.** `Sources/SketchyBarStudio/Views/BarRenderView.swift`, `Sources/SketchyBarStudio/Views/BarRenderProfilePicker.swift`, `Sources/SketchyBarStudio/Services/BarRendererService.swift`.

**Modify.** `Sources/SketchyBarStudio/Views/DetailView.swift`, `Sources/SketchyBarStudio/Stores/SketchyBarStore.swift` (state for the toggle and the picker), `Sources/SketchyBarStudio/Views/BarPreviewView.swift` only where it has to hand the draft to the new pane.

**Do not touch.** `Sources/SketchyBarStudio/Services/SbarLuaItemParser.swift`, `Sources/SketchyBarStudio/Services/LuaTableParser.swift`, `dist/`, and any file under a user config root.

## Acceptance criteria

* A user can open the preview of a config that is not the live one, and see a bar, and the rendered image has the width of the virtual display and is not blank.
* The preview of the live config shows the unsaved draft of the selected file.
* The 1:1 toggle shows the image at its true POINT size (one image pixel per device pixel on a 2× display), and the pane scrolls horizontally.
* Switching between Edit and Preview does not lose a draft.
* In the scaled-to-fit view the drawn image has the same width-to-height ratio as the rendered image, and the rendered image has the ratio of the target display width against the bar height. Checkable by comparing the two ratios.
* The fitted image's aspect ratio equals the rendered image's aspect ratio within 0.1%.
* The scaled-to-fit view applies the same factor to both axes. Checkable by measuring the drawn width and height against the image size.
* The preview never re-lays the bar out to the panel's shape: the number of items in the rendered image is the number of items in the config, whatever the pane width.
* The width used for the render is the target display's real width in points, unless the user overrides it, and the override is shown in the UI.
* The width override changes the bar's proportions: a different width produces a different aspect ratio, and the bar is still drawn at its true size in the view.

## Tests

`ViewLogicTests.swift` (existing file) gains a test for the toggle state and for the picker default. A render test asserts the image size matches the virtual display, not the pane: the image width is the target display width in points times 2, and the image height is the bar height in points times 2. A view test asserts the fitted image's aspect ratio equals the rendered image's aspect ratio within 0.1%, that the 1:1 pane scrolls horizontally, and that the width override changes the bar's proportions.

## Risks and unknowns

* The pane is far narrower than the bar, so the scaled-to-fit view is small. That is the decision, and the 1:1 toggle exists for the checks that need real pixels.
* The target display is not always the main screen (an external display may be the one the user is aiming at). The picker and the width override have to name the display they use.
* The existing `BarPreviewView` and the new pane can disagree about the item order, which would make the preview misleading. The reordering affordances stay in the old view, so both views have to read the same draft.

## Done when

The user can open the preview of any config or profile from the detail view, the scaled-to-fit view keeps the real menu-bar proportions, the 1:1 view scrolls horizontally, drafts survive the Edit / Preview switch, the tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.

## Follow-up: the interactive simulation

The pane is the editor of the bar now. The render returns the bar-relative
rectangle of every item and the file that declared it (`BarRenderResult`,
`BarRenderOrigin`), and the pane puts a hit target on each rectangle. The
target uses the same geometry as the image: the drawn point count per point
of the bar is `drawnSize.width / (image.width / 2)`.

* A click selects the item and selects its file in the store, a double-click
  opens the structured editor, and a click on the empty part of the bar clears
  the selection. The selection follows `selectedFileID`, and the first
  declaration of a file wins when a file declares more than one item.
* A drag carries the alias of the item. A drop picks the third of the bar under
  the pointer as the position, and the next item of that third as the place.
  A move between entrypoints changes only the position; the loader order is
  left alone. A shell item keeps its position in its `--add` line, so that
  move is refused with a message.
* The width handle uses a named coordinate space and keeps the start point, so
  a handle that moves under the pointer does not feed its own movement back
  into the width.
* The inspector edits the same drafts as the structured editor: position,
  label, icon, width and colours of an item, and position, height, margin,
  padding and colour of the bar. It reads the last declaration of a key,
  because SketchyBar applies the last assignment.
* The render key follows the drafts, the loader order, the activation state,
  the display and the width override. A 120 ms wait collapses a run of
  keystrokes into one render. A bar with scripts reads the revision of the
  script runner on a one-second timer and repaints only when the scripts
  produced values.

`Tests/SketchyBarStudioTests/BarSimulationTests.swift` covers the geometry,
the drop position and target, the render origins, the staged order and the bar
value lookup.
