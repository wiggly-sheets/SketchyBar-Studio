# Stage 2 — Headless item tree and the C API exposed to Swift

## Goal

The vendored SketchyBar runs headlessly. A shim replaces the window-server and daemon files with a virtual display, in-memory window records, a bitmap surface and a no-op event source, and a small, stable C API exposes an item tree to Swift.

## Depends on

[Stage 1](phase-1-vendor-core.md) must be merged. The subset has to compile and link before the shim can replace anything.

## In scope / Out of scope

**In scope.** The shim files, the headless item tree, the C API, and the `fork_exec` replacement that can give a child process a preview environment.

**Out of scope.** The config bridge ([Stage 3](phase-3-config-bridge.md)), the layout and the paint ([Stage 4](phase-4-layout-and-render.md)), and the `PATH` shim that captures `--set` calls ([Stage 6](phase-6-live-values.md)).

## Tasks

1. Implement the shim files. They stand in for the dropped daemon files and provide:
   * a virtual display with a configurable frame and scale;
   * an in-memory window record instead of a SkyLight window;
   * a bitmap surface that hands a `CGImage` back to the caller instead of pushing it into a CALayer;
   * an event source that never fires (no window server, no input);
   * a `fork_exec` that can set a preview environment for the child process.

   The file names are in the module table in [README.md](README.md#module-and-file-table).
2. Implement the C API. It is deliberately narrow, so the Swift side never depends on SketchyBar internals.
3. Implement the item tree: `sb_preview_add_item` records an alias, `sb_preview_set_item` and `sb_preview_set_bar` record one key/value pair each. The recorded values are the input of the layout in [Stage 4](phase-4-layout-and-render.md).
4. Provide the `fork_exec` replacement `shim/sketchybar_preview_fork.c`. [Stage 6](phase-6-live-values.md) patches it to put the shim directory first on `PATH` and to set the sink variable.

### The C API

```c
/* Sources/CSketchyBar/include/sketchybar_preview.h */
#ifndef SKETCHYBAR_PREVIEW_H
#define SKETCHYBAR_PREVIEW_H
#include <CoreGraphics/CoreGraphics.h>

/* The target builds with -fvisibility=hidden (makefile:1), so the exports
   need an explicit default visibility. */
#define SB_API __attribute__((visibility("default")))

typedef struct sb_preview sb_preview_t;

SB_API sb_preview_t* sb_preview_create(void);
SB_API void          sb_preview_destroy(sb_preview_t* preview);

/* Bar level: key is a SketchyBar bar property, e.g. "position", "margin". */
SB_API int  sb_preview_set_bar(sb_preview_t* preview, const char* key, const char* value);

/* Item level: alias first, then one property at a time. */
SB_API int  sb_preview_add_item(sb_preview_t* preview, const char* alias);
SB_API int  sb_preview_set_item(sb_preview_t* preview, const char* alias,
                                const char* key, const char* value);

/* Renders into a bitmap and returns a retained CGImage. */
SB_API CGImageRef sb_preview_render(sb_preview_t* preview);

/* The origin and size of one item, in pixels, after layout. */
SB_API int sb_preview_item_rect(sb_preview_t* preview, const char* alias,
                                CGRect* outRect);

/* Messages the vendored code produced, one per line. */
SB_API const char* sb_preview_messages(sb_preview_t* preview);
#endif
```

`sb_preview_render` and `sb_preview_item_rect` are declared here and implemented in [Stage 4](phase-4-layout-and-render.md).

## Files

**Create.** `Sources/CSketchyBar/shim/sketchybar_preview_display.c`, `Sources/CSketchyBar/shim/sketchybar_preview_window.c`, `Sources/CSketchyBar/shim/sketchybar_preview_surface.c`, `Sources/CSketchyBar/shim/sketchybar_preview_shim.c`, `Sources/CSketchyBar/shim/sketchybar_preview_fork.c`, and the item-tree implementation in `Sources/CSketchyBar/src/`.

**Modify.** `Sources/CSketchyBar/include/sketchybar_preview.h`, `Sources/CSketchyBar/MODIFICATIONS.md` (every patch to a vendored file).

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `dist/`, and any file under a user config root.

## Acceptance criteria

* `sb_preview_create`, `sb_preview_set_bar`, `sb_preview_add_item`, `sb_preview_set_item` and `sb_preview_destroy` are callable from Swift and link into the app.
* A create / add / set / destroy cycle opens no window and makes no connection to the Mach service. Checkable: no window appears in the accessibility list, and no connection to the Mach service appears for the process.
* The vendored tree no longer calls into a SkyLight window. Checkable: the compiled target contains no reference to `SLSNewWindowWithOpaqueShapeAndContext` (`src/window.c:65`) and no call to `window_set_frame` on a real window.
* `otool -L` on the built binary shows no SkyLight, DisplayServices or MediaRemote.
* Every patch to a vendored file is listed in `Sources/CSketchyBar/MODIFICATIONS.md`.
* A preview that is created and destroyed a thousand times in a loop leaves the process with the same number of open file descriptors and the same resident memory within one page.

## Tests

A C-level smoke test, driven from Swift: create a preview, add one item with a fixed width, set one property on it, destroy the preview, and assert that the cycle completes without a crash. A soak test runs the same cycle a thousand times and asserts that the file-descriptor count and the resident memory do not grow. The render assertion is [Stage 4](phase-4-layout-and-render.md).

## Risks and unknowns

* The preview leaks memory or file descriptors over a long session. The app slows down or crashes. Mitigation: the preview is created and destroyed per render, and the soak test above runs the live-value loop's shape.
* The item tree has no defined error semantics yet. The API returns `int`; agree on the meaning (0 for success) in this stage and use it consistently, because the config bridge in [Stage 3](phase-3-config-bridge.md) and the script runner in [Stage 6](phase-6-live-values.md) both report failures through it.

## Done when

The item tree can be filled from Swift through the C API, the shim replaces the window-server files, no window and no Mach connection exist during a render cycle, `MODIFICATIONS.md` lists every patch, and the branch is merged into master with `git merge --no-ff` and master is green.
