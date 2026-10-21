#ifndef SKETCHYBAR_PREVIEW_SHIM_H
#define SKETCHYBAR_PREVIEW_SHIM_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

/* Internal API of the preview shim.
   This header is private to the CSketchyBar target: it lives outside the
   public headers directory, so Swift never sees it. The public API is
   include/sketchybar_preview.h. */

/* The virtual display the preview draws for. The daemon asks the window
   server for the real displays; the preview has none, so it uses this id
   and the frame below. */
#define PREVIEW_DISPLAY_ID 1
#define PREVIEW_DISPLAY_WIDTH 1440.0
#define PREVIEW_DISPLAY_HEIGHT 900.0

/* The one virtual space of the virtual display. */
#define PREVIEW_SPACE_ID 1

/* The space type the daemon reads from SkyLight. Type 4 is a fullscreen
   space, in which SketchyBar hides the bar. */
#define PREVIEW_SPACE_TYPE_FULLSCREEN 4

/* The Space helpers replace the SkyLight calls of src/misc/helpers.h. The
   preview has exactly one space, so every helper answers for it. */
int preview_space_index(uint64_t space_id);
uint64_t preview_space_display_id(uint32_t space_index);
uint32_t preview_display_id_for_space(uint32_t space_index);
int preview_space_type(uint64_t space_id);
CGImageRef preview_space_capture(uint32_t space_index);

/* fork_exec and sync_exec are the daemon's script runner. They live in
   shim/sketchybar_preview_fork.c so the preview can give a child process
   its own environment. */
struct env_vars;
bool fork_exec(char* command, struct env_vars* env_vars);
bool sync_exec(char* command, struct env_vars* env_vars);

#endif
