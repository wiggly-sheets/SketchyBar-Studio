# Modifications

Every change this project makes to the vendored SketchyBar files. The
patches live in `script/vendor_stage1.py`, which copies the upstream files
and applies them, so the tree can be rebuilt from a clean checkout of the
upstream commit.

The vendored tree holds three kinds of code:

* `src/` — the upstream files, copied and patched by the script.
* `shim/` — the replacements of the dropped daemon files. They are written
  by this project and never overwritten by the script.
* `preview/` — the code of the preview itself: the C API, the item tree,
  the lifecycle of the bar manager and the symbols the dropped files would
  have defined. It is written by this project and never overwritten by the
  script.

Nothing else in the vendored tree is touched. The files that are not
vendored are listed in [UPSTREAM.md](UPSTREAM.md).

## The directory of the preview

`preview/` is new in stage 2. It holds the code that is neither upstream
code nor a replacement of a dropped upstream file:

```
preview/preview_internal.h            the internal API of the preview
preview/sketchybar_preview.c          the public C API and the item tree
preview/sketchybar_preview_bar.c      the bar manager and the bar domain
preview/sketchybar_preview_render.c   the layout and the render to a CGImage
preview/sketchybar_preview_stubs.c    the symbols of the dropped files
preview/sketchybar_preview_test.c     the test-only accessors
```

The stage file of stage 2 puts the item tree in `src/`. It does not: the
vendor script empties `src/` on every run (`script/vendor_stage1.py`), so a
new file there would be deleted by the next run of the script. The script
now refuses to run if the preview code ever moves into `src/`.

The handle owns the model of the vendored core while it is alive. The
vendored core keeps that model in one global bar manager, so only one
preview exists at a time: `sb_preview_create` returns `NULL` when another
preview is alive, and `sb_preview_destroy` releases the model of the live
handle. A handle that is not the live one was already released, so a second
call does nothing. The model must not be destroyed twice, because
`bar_manager_destroy` frees the bars of the manager without resetting them
(`src/bar_manager.c:1063`).

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
  environment for the child process. Stage 6 adds the `PATH` shim and the
  sink variable.
* `#define PREVIEW_SCRIPT_TIMEOUT 3` is new. The daemon gives a script of
  an item 60 seconds (`FORK_TIMEOUT`), and the preview gives it three: the
  preview is interactive, so a script that hangs must not hold the app. The
  value is a decision of this project, and the patch lives in
  `script/vendor_stage1.py`.
* `respond` writes its answer to the reply stream only. The daemon copies
  every answer to stdout, with a timestamp in front of it, so a rejected
  property printed a line in the app. The preview has no log.
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
* `bar_calculate_bounds_top_bottom` and `bar_get_frame` do not ask
  CoreGraphics whether the display is built-in. The id of the virtual
  display is 1, which is the id of the built-in display of a real Mac, so
  the answer would depend on the machine: the notch width of the bar would
  be 200 on some hosts and 0 on others. The preview models the notch of
  the virtual display instead: `preview_display_has_notch()` answers
  whether the virtual display is the built-in display of the machine, and
  the caller sets it with `sb_preview_set_notch`. The width, the offset and
  the height of the notch are the bar properties `notch_width`,
  `notch_offset` and `notch_display_height`, exactly as in the daemon.

## `src/bar_manager.c`

* The same space type check as in `src/bar.c`, for every bar.
* The loop that sends a message to the Mach port of every item is gone. The
  event ports belong to the Mach machinery of the daemon, and the preview
  has no event ports.
* `bar_manager_destroy` only removes the clock of the daemon when there is
  one. The clock is a 1 Hz timer on the main run loop of the app, and the
  preview never creates it, so the timer was always `NULL` and
  `CFRunLoopTimerInvalidate(NULL)` would have crashed.

## `src/bar_item.c`

* The block that sends the serialized environment of an item to its Mach
  port is gone, for the same reason.
* `bar_item_set_event_port()` is gone, for the same reason.
* The `mach_helper` property answers with a message instead of registering
  an event port: `The event_port property is not available in the preview`.
  The text lands in the message buffer of the preview. It is not a bug of
  the preview and it is not worked around: a config of stage 3 that sets
  `mach_helper` gets that message, and the app shows it.
* `bar_item->event_port = 0;` in `bar_item_init` is gone, because the field
  is gone.
* The condition that decides whether an item updates no longer tests
  `bar_item->event_port`.

## `src/bar_item.h`

* The field `mach_port_t event_port;` is gone, because the Mach machinery
  of the daemon is not vendored.

## `src/animation.c`

* `animator_renew_display_link` never creates the display link. The daemon
  drives its animations from the display link of the window server, and the
  preview has no window server: the link would only wake the app up for
  nothing. The callback stays reachable, so the file still compiles without
  a warning, and the block can only run when a display link exists, which
  never happens in the preview.

  This is what keeps `animator_add` (`src/animation.c:189`) from starting a
  display link, which the path of the property `width = dynamic` reaches
  (`src/bar_item.c:1251`, `src/text.c:1164`) whatever the duration of the
  animator is.

## `src/alias.c`

* `get_menu_item_list` returns an empty list. The enumeration of the menu
  bar items needs the window server, and the preview has none.
* `alias_get_permission` never asks for the Screen Recording permission.
  The permission stays false, so the alias item draws its placeholder.
* `print_all_menu_items` does not ask for the Screen Recording permission
  either.

  The three changes together mean that the alias item never touches the
  window server: neither `alias_setup` nor `alias_update` can reach
  `CGWindowListCopyWindowInfo` or `CGRequestScreenCaptureAccess`. The app
  never shows a Screen Recording prompt because a config holds an alias
  item. `window_capture` was already stubbed in stage 1.

## Files that are not vendored

The decision about `src/display_nsscreen.m` is part of this stage. The file
is the NSScreen-backed display provider: it reports the screens of the
machine. The preview draws for a virtual display, so the provider is not
vendored. It was only used by `src/display.c`, which is not vendored
either.

The other files that are not vendored are listed in
[UPSTREAM.md](UPSTREAM.md) with their reason.

## The decisions of stage 2

The review of stage 1 raised seventeen hazards. Every one of them is
handled here, and this is where the decision lives.

The citations of the form `src/file.c:12` are the lines of the upstream
checkout, like in [reference.md](../../docs/bar-renderer/reference.md),
unless the file is a file of the preview or of the shim, where they are the
lines of this tree.

| # | Decision | Where |
| --- | --- | --- |
| H1 | `bar_manager_init` is never called. It starts a `CVDisplayLink` and a 1 Hz `CFRunLoopTimer` on the main run loop of the app. The preview initialises the global bar manager itself, field for field, and leaves the clock out. | `preview/sketchybar_preview_bar.c:26` (`preview_bar_manager_init`) |
| H2 | The duration of the animator stays 0, so the `ANIMATE` macro never creates an animation. | `shim/sketchybar_preview_shim.c:24` (the comment on `g_bar_manager`) and `preview/sketchybar_preview_bar.c:79` |
| H3 | `animator_update` is never called, so no animation ever progresses. A preview is a still image. | no call site; `preview/sketchybar_preview_bar.c` |
| H4 | There is exactly one default item: `g_bar_manager.default_item`. The preview does not keep a second one. | `preview/sketchybar_preview_bar.c:70` (`bar_item_init(&bar_manager->default_item, NULL)`) |
| H5 | The virtual display has a configurable frame. The scale of the backing bitmap is the fixed scale of 2.0 of SketchyBar, and the argument of `sb_preview_set_display` is ignored. The default frame is 1440 x 900 points. | `shim/preview_shim.h:18` and `shim/sketchybar_preview_display.c:19` |
| H6 | The menu bar of the virtual display is modelled. The default is no menu bar at all, so the bar of the preview sits at the top of the display. The caller sets it with `sb_preview_set_menu_bar`, after the display. | `shim/preview_shim.h:30` and `shim/sketchybar_preview_display.c:27` |
| H7 | The id of the display is the fake id 1. The bar never asks CoreGraphics whether the display is built-in, so the notch width is 0 on every host. The notch of the virtual display is a parameter of the preview (`sb_preview_set_notch`), so a notched Mac can be reproduced. | `shim/preview_shim.h:17` and the patch of `src/bar.c` above |
| H8 | Every symbol the kept headers declare and the dropped files define is defined in the preview as a safe no-op. None of them is called by the vendored tree. | `preview/sketchybar_preview_stubs.c` |
| H9 | The alias item never touches the window server. The enumeration of the menu bar items and the request of the Screen Recording permission are gone. | `src/alias.c`, the three patches above |
| H10 | The script runner builds the environment of the child in the parent and hands it over with `execve`, so the environment of the app is never changed. The child never gets `BAR_NAME`. The runner forks instead of `vfork`ing. | `shim/sketchybar_preview_fork.c:72` (`preview_build_environment`) and `shim/sketchybar_preview_fork.c:141` (`fork_exec`) |
| H11 | The messages come from the reply stream of the parsers. The preview opens a memory stream, runs the parser and keeps the text until the next message. | `preview/sketchybar_preview.c:69` (`preview_apply_item_property`) |
| H12 | Every export carries `SB_API` and every file that defines one includes the public header before the definition. | `include/sketchybar_preview.h` and `preview/sketchybar_preview.c:5` |
| H13 | No new file lives in `src/`. The code of the preview lives in `preview/`, and the vendor script refuses to run if it ever moves into `src/`. | `preview/` and `script/vendor_stage1.py:26` |
| H14 | `-fno-modules` stays in the settings of the C target. `src/group.h` declares `struct group`, which clashes with the Darwin module. | `Package.swift` |
| H15 | `g_bar_manager` stays in the shim. Nineteen vendored files refer to it. | `shim/sketchybar_preview_shim.c:24` |
| H16 | The `mach_helper` property answers with a message. The text lands in the message buffer of the preview and is not worked around. | `src/bar_item.c`, the patch above |
| H17 | No `TODO` and no `FIXME` is left in the tree. | the whole tree |

### H4 in detail

Stage 1 kept two default items: the one of the preview and the one of the
vendored core, `g_bar_manager.default_item`. The vendored core uses its own
in three places that the preview cannot avoid:

* `bar_item_parse_set_message` compares the item with
  `&g_bar_manager.default_item` before it accepts a property of a graph, an
  alias, a slider or a ring (`src/bar_item.c:1155`, `src/bar_item.c:1165`,
  `src/bar_item.c:1175`, `src/bar_item.c:1185`).
* `COMMAND_DEFAULT_RESET` empties it (`src/bar_item.c:1378`).
* Every item inherits from it (`src/bar_manager.c:463`).

The preview therefore uses `g_bar_manager.default_item` as its one default
item, and it does not keep a second one. `sb_preview_set_default` writes to
it, `--default reset` empties it, and every item inherits from it, so the
three answers are the same struct. The preview resets it by destroying it
first, because the reset of the daemon leaves the memory of the old item
behind.

The items of the preview live in `g_bar_manager.bar_items`, because the
layout of stage 4 reads them from there (`src/bar_manager.c:323`,
`src/animation.c:103`).

### H5 and H6 in detail

`sb_preview_set_display(widthPoints, heightPoints, scale)` sets the frame
of the virtual display. The scale of the bitmap is the fixed scale of 2.0 of
SketchyBar (`src/surface.c:47`), which is what the stage file of stage 2
asks for, so the preview keeps it and ignores the argument: the scale of the
screen is not a parameter of the layout.

The menu bar of the display is a part of the display, so it is set with it.
The default is a display without a menu bar: the bar of the preview sits at
the top of the display, at y = 0. The reason is the fixed 480 x 25 points
display of the golden test (`docs/bar-renderer/testing.md`): its whole
height is the bar, so a menu bar of 24 points would push the bar out of the
display. The menu bar of the machine is a property of the machine, not of
the config, so the preview models it and lets the caller set it:
`sb_preview_set_menu_bar(heightPoints)` in `include/sketchybar_preview.h`.
The call comes after `sb_preview_set_display`, because the menu bar does
not change the geometry of the display. The differential test of stage 8
needs it, so that the vertical origin of the bar of the preview is the
vertical origin of the bar of the machine.

The id of the display is the fake id 1. The bar never asks CoreGraphics
whether the display is built-in, so the notch width of the bar is 0 on
every host (`src/bar.c:201`). A notched Mac cannot be reproduced in the
preview and that is accepted.

### H10 in detail

The daemon sets the variables of the item in the parent process
(`src/misc/helpers.h:441-447`), which would change the environment of
SketchyBar Studio itself, and it runs the child with `vfork`, whose child
may not touch the memory of the parent.

The preview builds the environment of the child from the environment of the
app, applies the variables of the item, removes `BAR_NAME` and adds
`SKETCHYBAR_PREVIEW=1`. The child gets that environment through `execve`,
so the environment of the app is never changed. `BAR_NAME` is removed even
when the variables of the item hold it: the daemon sets it for its own
children (`src/sketchybar.c:208`), and a script of the preview must never
believe it talks to the real daemon.

The environment is built in the parent, before the fork. The child of a
forked process must not call `malloc`: the allocator of a multithreaded
process can be locked by another thread at the moment of the fork, and the
child would deadlock on that lock. The child only calls the functions that
are safe in a signal handler: `alarm`, `execve` and `_exit`.

The daemon reaps the children of its scripts with `signal(SIGCHLD, SIG_IGN)`
(`src/sketchybar.c:139`). The app does not do that yet, because it runs no
script until stage 6. Stage 6 has to reap the children of the scripts it
runs, or the app collects a zombie for every script.

## `shim/sketchybar_preview_fork.c`

The file is the script runner of the preview, and stage 6 makes it run the
scripts of the items of the preview.

* The child of a script gets a `PATH` whose first entry is the directory of
  the shim. The directory of the real `sketchybar` is removed from the
  `PATH`, so a script that resolves the binary by name cannot reach the
  daemon. The directories `/bin` and `/usr/bin` are always on the `PATH`,
  because the child runs `/usr/bin/env sh -c` and `env` resolves the shell
  through the `PATH`.
* The child gets the variable `SKETCHYBAR_STUDIO_PREVIEW_SINK`, which
  carries the path of the file the shim writes to.
* The alarm of the child is `PREVIEW_SCRIPT_TIMEOUT` (three seconds), not
  the `FORK_TIMEOUT` of the daemon (60 seconds). The default action of the
  signal terminates the child, and the disposition of the signal is set
  again in the child, so a process that ignores the alarm does not pass
  that on to the script.
* The standard error and the standard output of every script go into a log
  file of its own, in the directory of the logs. The file is opened in the
  parent, because the child of a forked process must not call `open`.
* The children of the scripts are tracked and reaped. The daemon ignores
  `SIGCHLD` (`src/sketchybar.c:139`), and the preview waits for its
  children, so the app collects no zombie.
* A script that runs longer than the timeout is reported: the child dies
  with `SIGALRM`, and the parent kills the children that are still running
  when the deadline is over.
* The route that runs the scripts by their text forks every script of the
  batch at once and waits once, so the batch has one deadline: N scripts
  that hang cost one timeout and not N of them.
* `sync_exec` runs the command in a child and waits for it. The daemon
  replaces its own process with the command (`src/misc/helpers.h:441-447`),
  and the preview must never replace the app.
* A child that cannot be forked is counted and reported: the script did not
  run at all, and the preview says so.

## `shim/sketchybar_preview_state.c`

The state of the items between two runs of the scripts: the counter of every
item and the fact that it was on a bar. The daemon keeps that state in the
item, which lives as long as the config (`src/bar_item.c:126-133`). The
preview rebuilds its item tree on every render and on every tick of the
timer, so the state lives here and goes back into the item when the tree is
built again.

## `shim/preview_shim.h`

The declarations of the script runner of the preview: the environment of
the scripts, the alias of the script that is forked next, the run of one
script, the wait for the children and the messages of the run.

## `preview/sketchybar_preview.c` and `include/sketchybar_preview.h`

The API of the scripts of the preview:

* `sb_preview_set_script_environment` sets the directory of the shim, the
  path of the sink and the directory of the logs. The setting is global,
  because the runner of the scripts is global.
* `sb_preview_run_item_scripts` runs the script of every item of the
  preview that has one, the way the daemon runs it: the routine of the item
  and nothing else (`src/bar_manager.c:554`).
* `sb_preview_run_scripts` runs several scripts by their text, for a caller
  that has no tree of items. The whole batch is forked at once and the wait
  happens once.
* `sb_preview_item_script` answers the script of an item, which can be one
  the config does not set: a space item gets the script of the daemon
  (`src/bar_item.c:428-431`).
* `sb_preview_script_messages` answers the messages of the last run.
* The codes `SB_ERR_SCRIPT_TIMEOUT` and `SB_ERR_SCRIPT_FAILED` are new.
  The codes that were there stay the same.

### H8 in detail

The kept headers of the dropped modules stay in the tree, because the kept
code includes them. The implementations of the dropped files are gone, so
the link would fail the moment a later stage calls one of the symbols. They
are defined in `preview/sketchybar_preview_stubs.c` as the safe no-ops they
have to be. None of them is called by the vendored tree today, and the
check of that is a grep over `src/` and `shim/`:

| Symbol | Called by the vendored tree | The definition |
| --- | --- | --- |
| `source_pid_needs_workaround` | no | answers false |
| `source_name_for_window` | no | answers NULL |
| `source_pid_cache_init` | no | does nothing |
| `source_pid_cache_refresh` | no | does nothing |
| `workspace_event_handler_init` | no | does nothing |
| `workspace_event_handler_begin` | no | does nothing |
| `workspace_event_handler_end` | no | does nothing |
| `workspace_display_notch_height` | no | answers 0 |
| `workspace_copy_app_name_for_pid` | no | answers NULL |
| `initialize_media_events` | no | does nothing |
| `mouse_begin` | no | does nothing |

## The decisions of stage 4

Stage 4 lays the bar out and paints it into a bitmap. The render path is
the code of the preview, in `preview/sketchybar_preview_render.c`, and it
uses the vendored code as it is. The one file of `src/` that stage 4
patches is `src/bar.c`: the notch of the virtual display is a parameter of
the preview, so the bar asks the shim whether the virtual display is the
built-in display of the machine instead of asking CoreGraphics. The patch
lives in `script/vendor_stage1.py`, so the script reproduces the committed
`src/` byte for byte.

| # | Decision | Where |
| --- | --- | --- |
| S1 | The layout and the draw run through the vendored code: `bar_manager_refresh` with the forced flag (`src/bar_manager.c:424-447`), which lays the bounds out, draws the bar and orders the item windows. | `preview/sketchybar_preview_render.c` (`preview_layout`) |
| S2 | The image is the frame of the bar, at the fixed backing scale of 2.0. The bar draws itself into the image and so does every item, at the place the layout gave it. The bar background of the daemon is the window of the bar and every item is its own window (`src/bar.c:140-198`), so the image is the composition of the bitmaps of those windows. | `preview/sketchybar_preview_render.c` (`preview_compose`) |
| S3 | Every rectangle the API reports is in points, in the coordinate system of the virtual display, exactly like the `bounding_rects` of `sketchybar --query <item>` (`src/bar_item.c:1065-1079`). The bitmap is twice the size of the point geometry. | `preview/sketchybar_preview_render.c` (`sb_preview_item_rect`) |
| S4 | The C API has no default for the width of the virtual display: the caller always passes one. The default belongs to the caller, because the width of the target display is a property of the machine. The Swift wrapper derives it from the target `NSScreen`. The C default, used when the caller never sets a display, stays 1440 x 900 points. | `include/sketchybar_preview.h`, `Sources/SketchyBarStudio/Support/SketchyBarPreviewC.swift` |
| S5 | The backing scale is the fixed scale of 2.0 of SketchyBar, whatever the scale of the display is. The argument of `sb_preview_set_display` is ignored, as in stage 2. | `include/sketchybar_preview.h` |
| S6 | The height of the bar comes from the config, not from the display: it is the height of the background of the bar, 25 points by default (`src/bar_manager.c:51`). The height of the display is the height of the screen. | `preview/sketchybar_preview_render.c` (`preview_compose`) |
| S7 | The menu bar of the virtual display moves the bar down (`src/bar.c:484-487`). The menu bar is set before the render, and the render lays the bar out again, so the vertical origin of the bar and the rectangles of the items follow it. | `shim/sketchybar_preview_display.c`, `preview/sketchybar_preview_render.c` |
| S8 | An alias item and a space item show the content of the window server, which the preview does not have. They keep a box of 16 points, a width CHOSEN BY THIS PROJECT, and the render draws the box into the bitmap of the item itself, so the item keeps its place on the bar and an export of the item alone shows the box too. A width of the config wins over the placeholder. | `preview/sketchybar_preview.c` (`preview_apply_placeholder`), `preview/sketchybar_preview_render.c` (`preview_draw_placeholder`) |
| S9 | The add of an item takes the four arguments of the add command of the daemon: the type, the position and the trailing argument (`src/message.c:180-256`). The preview can hold an alias or a space item, and it can lay out a graph, a slider or a ring. A bracket groups its members, the way the daemon does (`src/message.c:262-306`). A type the daemon does not know leaves the item a plain item, and the answer says so. | `preview/sketchybar_preview.c` (`sb_preview_add_item`) |
| S10 | The frame of the bar is part of the API (`sb_preview_bar_frame`), so a consumer does not have to recompute the origin of the bar to map a rectangle of an item onto the image. | `preview/sketchybar_preview_render.c` (`sb_preview_bar_frame`) |
| S11 | The items are drawn in the order of the windows of the daemon (`src/bar.c:82-111`), so an item that overlaps another one is drawn in the same order as on the screen. The shim keeps the order of every window. | `preview/sketchybar_preview_render.c` (`preview_window_depth`) |
| S12 | The notch of the virtual display is a parameter of the display (`sb_preview_set_notch`), so a notched Mac can be reproduced. | `shim/sketchybar_preview_display.c`, the patch of `src/bar.c` above |
| S13 | A window of no size keeps a bitmap of one point, so the draw of the bar never calls CoreGraphics with a NULL context (`src/context.c:6-8`, `src/bar.c:188`). A graph without a width is refused, because the daemon divides by the width of the graph (`src/graph.c:24`) and crashes. | `shim/sketchybar_preview_surface.c`, `preview/sketchybar_preview.c` |

### S2 in detail

The daemon draws the background of the bar into the window of the bar and
every item into its own window (`src/bar.c:140-198`). The preview has no
window server, so the windows are records in memory
(`shim/sketchybar_preview_window.c`) and their surfaces are bitmaps
(`shim/sketchybar_preview_surface.c`). The render puts the bitmaps of the
windows together into one image, the way the screen shows the windows of the
bar: the bitmap of the bar at the margin of the bar, and the bitmap of every
item at the origin of its window.

The image is the frame of the bar, so the margins of the bar stay empty as
they are on the screen, and a bar on the left or on the right of the display
has the shape of that bar. A bar of 480 x 25 points gives an image of
960 x 50 pixels.

The origin of the image is the origin of the bar in the coordinate system of
the display, so the rectangle of an item maps onto the image with
`image_x = rect.origin.x - barFrame.origin.x` and
`image_y = rect.origin.y - barFrame.origin.y`, and the pixel is the point
times 2.

### S8 in detail

An alias item draws a captured menu bar item (`src/alias.c:206-223`) and a
space item draws a captured space (`src/image.c:67-76`). Both need the
window server, and the preview has none: the vendored `alias.c` never
reaches it and never asks for the Screen Recording permission, so the alias
has no image and the space has no capture.

The placeholder is a box of 16 points. That width is a value CHOSEN BY THIS
PROJECT: the real width of an alias item is the width of the captured image
of the menu bar item, and a space is as wide as the captured space, so the
preview cannot know it. The box is drawn into the bitmap of the item itself
and not into the image of the bar, so the item keeps its place on the bar and
an export of the item alone shows the box too. The app warns about such an
item before it reaches the preview. The parser path of the app cannot read the
type of an item, so it drops the item and the preview never shows it
(`PreviewWarning.unsupportedType`). The Lua path reads the type and sends it
to the preview, so the item reaches the preview as a placeholder. The type of
`sb_preview_add_item` is there for the differential test of stage 8.

## The decisions of stage 6

Stage 6 runs the scripts of the items inside the preview. The scripts of
the items call `sketchybar`, and the preview must never change the live bar
of the user.

| # | Decision | Where |
| --- | --- | --- |
| L1 | The child of a script gets a `PATH` whose first entry is the directory of the shim, and the directory of the real `sketchybar` is removed from it. `/bin` and `/usr/bin` stay on it, because the shell of the child is resolved through the `PATH`. A directory that holds a file called `sketchybar` counts only when that file is a regular file, and a directory the preview cannot read counts as one. | `shim/sketchybar_preview_fork.c` (`preview_build_path`, `preview_directory_holds_binary`) |
| L2 | The shim writes into a sink file, and the path of the sink comes from the environment of the child. The shim, the sink and the logs live in a directory of their own with the mode 0700, and the preview removes that directory when the run is done. | `Sources/SketchyBarStudio/Services/PreviewScriptShim.swift` |
| L3 | A script of the preview has three seconds, not the sixty of the daemon. The value is a decision of this project. | `src/misc/helpers.h` (`PREVIEW_SCRIPT_TIMEOUT`), patched by `script/vendor_stage1.py` |
| L4 | The children of the scripts are tracked and reaped, and the standard error and the standard output of every script go into a log file of its own. The log is read whatever the exit code of the script is, so a script that succeeds but complains does not lose its message. A script that fails is a warning of the preview, with the report of the script. | `shim/sketchybar_preview_fork.c` (`preview_wait_for_scripts`) |
| L5 | The scripts of the items run through the routine of the daemon, `bar_item_update(item, NULL, false, NULL)` (`src/bar_manager.c:554`), so the gate of the daemon decides whether a script runs and the child gets the environment of the item itself: its name, its variables and the sender. | `preview/sketchybar_preview.c` (`sb_preview_run_item_scripts`) |
| L6 | The counter of an item and the fact that it was on a bar are kept between the trees, because the preview rebuilds its item tree on every render and on every tick. The cadence of the daemon therefore survives the rebuild. | `shim/sketchybar_preview_state.c` |
| L7 | The messages of a run of the scripts are separate from the messages of the properties, because the properties of an item are read after the scripts ran, and that read clears the messages of the properties. | `include/sketchybar_preview.h` |
| L8 | A script that calls the binary of the daemon by its absolute path is not intercepted: it reaches the live bar. A script that sets its own `PATH` can put the real binary in front of the shim. The preview warns about both, and the warning is the only thing the preview can do about them. | `Sources/SketchyBarStudio/Services/PreviewScriptRunner.swift` (`PreviewScriptWarning.absolutePath`, `PreviewScriptWarning.pathOverride`) |
| L9 | The route that runs the scripts by their text forks every script at once and waits once, so the batch has one deadline and not one deadline per script. | `shim/sketchybar_preview_fork.c` (`preview_run_scripts`), `preview/sketchybar_preview.c` (`sb_preview_run_scripts`) |
| L10 | `sync_exec` does not run the command in the process of the app: the daemon replaces its own process with the command, and the preview must not replace the app. The command runs in a child and the parent waits for it. | `shim/sketchybar_preview_fork.c` (`sync_exec`) |

### L1 in detail

The child of a script runs `/usr/bin/env sh -c <script>`, and `env`
resolves the shell through the `PATH`. A `PATH` without a shell means no
script at all, so the preview keeps `/bin` and `/usr/bin` on it.

The directories that hold a file called `sketchybar` are removed from the
`PATH` of the child. On this machine that is `/opt/homebrew/bin`, and a
script that calls `sketchybar` by name cannot reach the real daemon
through it.

Only a regular file counts: a directory or a socket called `sketchybar`
cannot be run, so the entry stays on the `PATH`. A directory the preview
cannot read counts as one, because "cannot tell" must not mean "the daemon
is reachable".

The limit of the mitigation is a script that calls the binary by its
absolute path: `/opt/homebrew/bin/sketchybar --set ...` reaches the daemon
and changes the live bar. The preview warns about such a script, so the
user knows that it was not intercepted.

### L5 and L6 in detail

The daemon runs the script of an item from its clock, with the routine of
the item and nothing else (`src/bar_manager.c:554`):

```c
bar_item_update(bar_item, NULL, forced, NULL);
```

That call is the whole rule of the daemon, and the preview uses it:

* `updates = false` never runs the script, an item without `update_freq`
  runs it only on an event, and `updates = when_shown` runs it only while
  the item is on a bar (`src/bar_item.c:127-139`). The preview runs the
  scripts the daemon runs, and no others.
* the counter of the item decides when the script runs
  (`src/bar_item.c:132-133`), so an item with `update_freq = 60` runs its
  script every 60 seconds.
* the child gets the environment of the item itself: the name of the item,
  the variables of the item and the sender (`src/bar_item.c:142-161`). The
  preview does not build that environment.

The daemon keeps its items for as long as the config lives, so the counter
of an item and the fact that it was on a bar survive there. The preview
rebuilds its item tree on every render and on every tick of the timer, so
both live in the registry of `shim/sketchybar_preview_state.c` and go back
into the item when the tree is built again. The key of the registry is the
alias of the item, which is the name of the item.


