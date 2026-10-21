# Modifications

Every change this project makes to the vendored SketchyBar files. The
patches live in `script/vendor_stage1.py`, which copies the upstream files
and applies them, so the tree can be rebuilt from a clean checkout of the
upstream commit.

Nothing else in the vendored tree is touched. The files that are not
vendored are listed in [UPSTREAM.md](UPSTREAM.md).

## `src/misc/helpers.h`

* `#include "extern.h"` became `#include "preview_shim.h"`. `extern.h`
  declares the SkyLight and DisplayServices entry points, and the preview
  has no window server.
* `mission_control_index`, `dsid_from_sid`, `space_capture` and
  `display_id_for_space` call the shim instead of SkyLight. The daemon
  reads the spaces of the machine from `SLSCopyManagedDisplaySpaces`,
  `SLSHWCaptureSpace` and `SLSCopyManagedDisplayForSpace`; the preview has
  one virtual space.
* `sync_exec` and `fork_exec` are no longer `static inline` functions of the
  header. They are declared here and defined in
  `shim/sketchybar_preview_fork.c`. Stage 2 makes `fork_exec` set a preview
  environment for the child process. Stage 6 only adds the `PATH` shim and
  the sink variable.
* `extern int g_connection;` is gone. The connection id of the window
  server means nothing in the preview.

## `src/event.h`

* `#include "message.h"` became `#include "display.h"`. `message.h` pulls in
  `mach.h`, which declares the Mach bootstrap server of the daemon. The
  kept code reached the display declarations through `message.h`, so
  `display.h` takes its place.

## `src/bar.c`

* The bar asks the window server for the type of its space:
  `SLSSpaceGetType(g_connection, bar->dsid) != 4`. The preview asks the
  shim: `preview_space_type(bar->dsid) != PREVIEW_SPACE_TYPE_FULLSCREEN`.
  The bar is hidden in a fullscreen space, and the shim has no fullscreen
  space.

## `src/bar_manager.c`

* The same space type check as in `src/bar.c`, for every bar.
* The loop that sends a message to the Mach port of every item is gone. The
  event ports belong to the Mach machinery of the daemon, and the preview
  has no event ports.

## `src/bar_item.c`

* The block that sends the serialized environment of an item to its Mach
  port is gone, for the same reason.
* `bar_item_set_event_port()` is gone, for the same reason.
* The `mach_helper` property answers with a message instead of registering
  an event port: `The event_port property is not available in the preview`.
* `bar_item->event_port = 0;` in `bar_item_init` is gone, because the field
  is gone.
* The condition that decides whether an item updates no longer tests
  `bar_item->event_port`.

## `src/bar_item.h`

* The field `mach_port_t event_port;` is gone, because the Mach machinery
  of the daemon is not vendored.

## Files that are not vendored

The decision about `src/display_nsscreen.m` is part of this stage. The file
is the NSScreen-backed display provider: it reports the screens of the
machine. The preview draws for a virtual display, so the provider is not
vendored. It was only used by `src/display.c`, which is not vendored
either.

The other files that are not vendored are listed in
[UPSTREAM.md](UPSTREAM.md) with their reason.
