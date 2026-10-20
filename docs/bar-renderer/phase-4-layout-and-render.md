# Stage 4 — Layout and offscreen render to a `CGImage`

## Goal

The vendored SketchyBar lays out and paints a bar into a bitmap, with no window server, no permission prompt and no live SketchyBar. The item rectangles it computes are the layout the rest of the feature depends on.

## Depends on

[Stage 3](phase-3-config-bridge.md) must be merged. There has to be an item tree to lay out.

## In scope / Out of scope

**In scope.** The virtual display defaults, the rewiring of the window-server calls, the render path, the item rectangles, and the visual output.

**Out of scope.** The preview pane ([Stage 5](phase-5-preview-pane.md)), the live values ([Stage 6](phase-6-live-values.md)), and the exactness work ([Stage 8](phase-8-exactness-and-diff.md)).

## Tasks

1. Set the default width, height and scale of the virtual display to the **target display's real width in points and that display's scale**, not to a fixed fake width. The width stays overridable, so a render can be made for another display or a fixture. The real menu-bar proportions depend on this: a SketchyBar bar is display width minus twice the margin (`src/bar.c:437-494`).
2. Rewire the vendored call sites. The kept subset still needs these call-pattern replacements:
   * `window_set_frame(bar_item_get_window(...))` → an in-memory frame record. The call sites are `src/bar.c:280` and `src/bar.c:404`; `bar_item_get_window` (`src/bar_item.c:556-583`) *creates* a window on demand (`window_open` at `src/bar_item.c:570` → `SLSNewWindowWithOpaqueShapeAndContext`, `src/window.c:65`), and `window_set_frame` itself (`src/window.c:158-170`) is pure bookkeeping.
   * `bar_item_get_window` → a struct that carries the item's frame.
   * Display lookups → the virtual display provider with a configurable width, height and scale.
3. Route the render through the bitmap surface: the surface hands the `CGImage` back to the caller instead of pushing it into a CALayer (`src/surface.c:67-75`, `src/layer.m:48-55`).
4. Implement `sb_preview_render` and `sb_preview_item_rect`.
5. Make the bar background, item backgrounds, borders, text and images appear.

The render path is already offscreen upstream: `src/context.c:11-26` creates a plain `CGBitmapContextCreate`, and `bar_item_draw` (`src/bar_item.c:842-856`) with its whole subtree (background, text, image, ring, slider, graph, alias, badge) is pure CoreGraphics/CoreText with no window-server dependency. The layout is about 455 lines and the reading aid is in [reference.md](reference.md#the-layout-algorithm-structurally).

## Files

**Create.** None required. The golden PNGs live with the tests in [Stage 8](phase-8-exactness-and-diff.md).

**Modify.** `Sources/CSketchyBar/src/bar.c`, `Sources/CSketchyBar/src/bar_item.c` (the patches only), `Sources/CSketchyBar/src/surface.c` if it is not already replaced by the shim, `Sources/CSketchyBar/shim/**`, `Sources/SketchyBarStudio/Support/SketchyBarPreviewC.swift`, `Sources/CSketchyBar/MODIFICATIONS.md`.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `dist/`, and any file under a user config root.

## Acceptance criteria

* A render of a config with three items returns a `CGImage` whose pixel width equals the virtual display width times the scale, and whose pixel height equals the bar height times the scale.
* `sb_preview_item_rect` returns a non-empty rect for every item.
* The process asks for no screen recording permission, creates no window, and does not talk to the Mach service. Checkable by the fact that no permission prompt appears, no window shows up in the accessibility list, and no connection to the Mach service appears.
* The rendered image is not blank: at least one pixel differs from the background.
* The default virtual display width equals the target display's real width in points, and an explicit override changes it.
* The bar background, the item backgrounds, the borders, the text and the images are all visible in the rendered image.

## Tests

`BarRenderGoldenTests.swift`: render a fixed config and compare the image against a stored PNG. The C-level smoke test from [Stage 1](phase-1-vendor-core.md) completes here: create a preview, add one item with a fixed width, render, and assert that a non-null `CGImage` of the expected pixel size comes back. The golden-image strategy is in [testing.md](testing.md).

## Risks and unknowns

* Open question 6: how does the fork's `space` item behave in a preview? It needs a Space capture, which needs the window server. The placeholder and its geometry are decided in this stage.
* The `alias` item draws a captured window image (`src/alias.c:260-300`). It cannot be produced headlessly; the placeholder and its geometry are decided in this stage, and the preview says so.
* The item semantics that decide the exactness of the layout — padding ownership, `align`, the icon-to-label offset, `width`, `y_offset`, `max_chars`, `scroll_texts`, the `space` marker and the group background — are listed in [reference.md](reference.md#item-semantics-that-matter-for-exactness). Read them before changing the layout.

## Done when

A config renders to a `CGImage` with the expected pixel size, every item has a non-empty rectangle, the image is not blank, no permission is asked for and no window appears, the golden test exists, and the branch is merged into master with `git merge --no-ff` and master is green.
