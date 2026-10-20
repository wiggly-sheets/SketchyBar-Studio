# Stage 1 — Vendor the SketchyBar subset as a SwiftPM C target

## Goal

The vendored SketchyBar subset compiles and links into the app as a SwiftPM C target. This is the highest-risk stage of the plan. The first compile is the gate. Do not start Stage 2 until the gate below is met.

## Depends on

[Stage 0](phase-0-license.md) must be merged. GPL-3.0 code cannot land in an MIT repository.

## In scope / Out of scope

**In scope.** Copying the subset into the repository, the `CSketchyBar` target in `Package.swift`, the public header, the compile gate and its keep/drop decision list, and the link proof from Swift.

**Out of scope.** The behaviour of the headless shim ([Stage 2](phase-2-headless-core.md)), the config bridge ([Stage 3](phase-3-config-bridge.md)), layout and painting ([Stage 4](phase-4-layout-and-render.md)), and anything that writes to a user config.

## Tasks

1. Copy the subset into `Sources/CSketchyBar/src`, with the upstream `LICENSE.md` and the upstream copyright notices intact.
2. Add the `CSketchyBar` target to `Package.swift` with `publicHeadersPath: "include"`, `-fvisibility=hidden` and the framework links the subset actually needs.
3. Write `include/sketchybar_preview.h`. The full API contract is in [Stage 2](phase-2-headless-core.md); the exports need an explicit default visibility because the target builds with `-fvisibility=hidden` (`makefile:1`).
4. Write the shim files listed in [Stage 2](phase-2-headless-core.md) in a form that compiles and returns safe defaults. Their behaviour is Stage 2 work.
5. Compile. For every unresolved or window-server symbol, decide: keep the file, stub the call, or drop the file. Record the decision in the commit message. The result is the authoritative keep/drop list and stub set.
6. Link the C target into the app and call `sb_preview_create` / `sb_preview_destroy` once, to prove the link works from Swift.

### The subset to vendor

Keep the parts that are pure CoreGraphics/CoreText and the item model. Drop the window-server and daemon parts:

```
DROP:
  src/window.c        src/surface.c      src/layer.m       src/display.c
  src/event.c         src/app_windows.c  src/mach.c        src/sketchybar.c
  src/workspace.m     src/source_pid.m   src/media.m       src/power.m
  src/volume.m        src/wifi.m
```

This list is a starting point, not the answer. Three files call the window server and are **not** in it, and each needs a decision in this stage:

* `src/alias.c` calls `window_capture` (`src/alias.c:237`) to grab the captured window image. Disposition: keep the item model, stub the capture, and render the `alias` item as a placeholder.
* `src/popup.c` creates and frames the popup window (`window_open` at `src/popup.c:383`, `window_set_frame` at `src/popup.c:375`). Disposition: stub the window, keep the popup geometry.
* `src/mouse.c` handles the mouse and the event tap. Disposition: drop it, and stub the callers.

`src/display_nsscreen.m` is not named in that list. It provides the NSScreen-backed display provider, and the preview needs a virtual display instead. Its fate is UNVERIFIED and is settled in this stage.

`src/symbol.m` is the only Objective-C file the subset is expected to need; it uses public AppKit APIs (`NSImage imageWithSystemSymbolName:variableValue:...`). SwiftPM C targets accept `.m` sources, but this is a compile risk in this stage.

The files that call into the window server are: `app_windows.c`, `bar_manager.c`, `bar.c`, `display.c`, `event.c`, `sketchybar.c`, `surface.c`, `window.c`, and `src/misc/helpers.h` (which holds `g_connection` at `src/misc/helpers.h:20` and the Space helpers at `src/misc/helpers.h:468`, `src/misc/helpers.h:496`, `src/misc/helpers.h:524`, `src/misc/helpers.h:537`). `bar.c` and `bar_manager.c` hold the layout code, so they stay and their window-server calls are stubbed: `SLSSpaceGetType(g_connection, …)` at `src/bar.c:543` and `src/bar_manager.c:956` both need a stub.

### The SwiftPM target

```
// swift-tools-version: 5.9
targets: [
    .target(
        name: "CSketchyBar",
        path: "Sources/CSketchyBar",
        publicHeadersPath: "include",
        cSettings: [
            .unsafeFlags(["-std=c99", "-fvisibility=hidden", "-fno-common"])
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("QuartzCore")
        ]
    ),
    ...
]
```

`-fvisibility=hidden` comes from the upstream `makefile:1`; the preview API header marks its own exports with a visibility attribute so the rest of the C code stays hidden. The framework list above is the *upper* bound from the `LIBS` block at `makefile:3-13`; the minimum set the subset actually needs is an output of this stage. The private frameworks (SkyLight, DisplayServices, MediaRemote) are not needed by the subset and must not be linked.

## Files

**Create.** `Sources/CSketchyBar/src/**` (the vendored subset), `Sources/CSketchyBar/include/sketchybar_preview.h`, `Sources/CSketchyBar/shim/**`, `Sources/CSketchyBar/LICENSE.md` (upstream licence), `Sources/CSketchyBar/MODIFICATIONS.md`, `Sources/CSketchyBar/UPSTREAM.md` (the upstream commit that was vendored), `Sources/SketchyBarStudio/Support/SketchyBarPreviewC.swift` (a thin Swift wrapper).

**Modify.** `Package.swift`.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `Sources/SketchyBarStudio/Services/**`, `dist/`, and any file under a user config root.

## Acceptance criteria

The gate:

* `swift build` succeeds with the C target in the graph.
* `sb_preview_create()` and `sb_preview_destroy()` are callable from Swift.
* No private framework is linked: `otool -L` on the built binary shows no SkyLight, DisplayServices or MediaRemote.
* The vendored tree contains the upstream licence and copyright notices, and a `Sources/CSketchyBar/MODIFICATIONS.md` lists every patch.
* The commit message contains the final keep/drop list and the stub list.
* `Sources/CSketchyBar/UPSTREAM.md` names the upstream commit that was copied.

## Tests

A C-level smoke test, driven from Swift: create a preview, add one item with a fixed width, destroy the preview, and assert that the cycle completes without a crash and without a leak. The render assertion of this test — a non-null `CGImage` of the expected pixel size — belongs to [Stage 4](phase-4-layout-and-render.md), which is where the render path is implemented.

## Risks and unknowns

* The vendored subset does not compile after the window-server files are stripped. Stage 1 fails and the whole plan stops. Mitigation: this stage is an explicit gate, and the compile happens here, before any other stage.
* `src/symbol.m` (Objective-C) does not fit a SwiftPM C target. SF Symbols cannot be drawn, so the render is not exact. Mitigation: verify here, first.
* Private frameworks leak back into the link. The app would need the same private entitlements as SketchyBar, and the bundle would break. Mitigation: the `otool -L` acceptance criterion.
* **Fallback if the gate fails.** If `src/symbol.m` cannot live in a SwiftPM C target, build the subset as a static library with a script under `script/` and link it through `.unsafeFlags(["-L..."])`. This keeps `swift build` working, at the cost of a non-portable package manifest. Record the choice.
* Open question 5: the fate of `src/display_nsscreen.m` is decided here. See [reference.md](reference.md#open-questions).

## Done when

The gate above is met, the keep/drop list and the stub list are in the commit message, `MODIFICATIONS.md` and `UPSTREAM.md` exist, and the branch is merged into master with `git merge --no-ff` and master is green.
