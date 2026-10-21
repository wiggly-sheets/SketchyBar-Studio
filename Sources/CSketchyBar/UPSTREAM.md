# Upstream

The C target `CSketchyBar` vendors a subset of
[SketchyBar](https://github.com/wiggly-sheets/SketchyBar.git).

| | |
|---|---|
| Repository | `https://github.com/wiggly-sheets/SketchyBar.git` |
| Commit | `f23f4f45302129aee7a2f6de6d6ae2cc9d7d7ed4` |
| Version | `v2.24.0-50-gf23f4f4` |
| Date | 2026-09-12 |
| Licence | GPL-3.0, see [LICENSE.md](LICENSE.md) |

The vendored tree is copied with `script/vendor_stage1.py`. The script
copies the files below and applies the patches of
[MODIFICATIONS.md](MODIFICATIONS.md). Run it after changing the patch list,
so the tree can be rebuilt from a clean checkout of the upstream commit.

The script only owns `src/`. The `shim/` and `preview/` directories hold
the code of this project: the replacements of the dropped daemon files and
the code of the preview itself. They are never overwritten by the script.

## Vendored files

The files that are compiled into the target:

```
src/alias.c            src/alias.h
src/animation.c        src/animation.h
src/background.c       src/background.h
src/bar.c              src/bar.h
src/bar_item.c         src/bar_item.h
src/bar_manager.c      src/bar_manager.h
src/color.c            src/color.h
src/context.c          src/context.h
src/custom_events.c    src/custom_events.h
src/font.c             src/font.h
src/graph.c            src/graph.h
src/group.c            src/group.h
src/image.c            src/image.h
src/popup.c            src/popup.h
src/ring.c             src/ring.h
src/shadow.c           src/shadow.h
src/slider.c           src/slider.h
src/symbol.h           src/symbol.m
src/text.c             src/text.h
src/misc/defines.h     src/misc/env_vars.h    src/misc/helpers.h
```

The headers of the modules that are not vendored. The kept code includes
them, so the declarations stay, but their implementations are gone and the
shim replaces them:

```
src/app_windows.h      src/display.h         src/event.h
src/media.h            src/mouse.h           src/power.h
src/source_pid.h       src/surface.h         src/volume.h
src/wifi.h             src/window.h          src/workspace.h
```

## The code of the preview

Neither upstream code nor a replacement of a dropped upstream file:

```
preview/preview_internal.h            the internal API of the preview
preview/sketchybar_preview.c          the public C API and the item tree
preview/sketchybar_preview_bar.c      the bar manager and the bar domain
preview/sketchybar_preview_stubs.c    the symbols of the dropped files
preview/sketchybar_preview_test.c     the test-only accessors
```

## Files that are not vendored

| Upstream file | Reason |
|---|---|
| `src/window.c` | Talks to the window server. The shim keeps the window records in memory. |
| `src/surface.c` | Pushes the surface into a CALayer of the window server. The shim draws into a bitmap. |
| `src/layer.m` | Only exists for the window server surfaces. |
| `src/layer.h` | The header of the dropped `src/layer.m`. The layer is a window server surface, so no file of the subset includes it. |
| `src/display.c` | Reads the real displays. The shim answers for one virtual display. |
| `src/display_nsscreen.m` | The NSScreen-backed display provider. The preview needs a virtual display, not the screens of the machine, so the file is not vendored. It was only used by the dropped `src/display.c`. |
| `src/display_nsscreen.h` | The header of the dropped `src/display_nsscreen.m`. The provider is gone, so no file of the subset includes it. |
| `src/event.c` | The event tap of the daemon. The preview has no input. |
| `src/app_windows.c` | Reads the windows of the applications. |
| `src/mach.c`, `src/mach.h` | The Mach bootstrap server of the daemon. |
| `src/message.c`, `src/message.h` | The message loop of the daemon. It depends on the Mach machinery. |
| `src/sketchybar.c` | The entry point of the daemon. |
| `src/workspace.m` | The workspace observer of the daemon. |
| `src/source_pid.m` | Finds the source process of a menu bar item with the accessibility API. |
| `src/media.m` | The media keys of the daemon. |
| `src/power.c`, `src/power.h` | The power events of the daemon. The header stays, the implementation does not. |
| `src/volume.c` | The volume events of the daemon. The header stays, the implementation does not. |
| `src/wifi.m` | The network events of the daemon. |
| `src/mouse.c` | The mouse handling and the event tap of the daemon. |
| `src/hotload.c`, `src/hotload.h` | The hot reload of the daemon. |
| `src/misc/extern.h` | Declares the SkyLight and DisplayServices entry points. |
| `src/misc/help.h` | The command line help of the daemon. |
