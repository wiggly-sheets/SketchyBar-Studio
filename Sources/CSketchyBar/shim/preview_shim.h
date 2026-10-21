#ifndef SKETCHYBAR_PREVIEW_SHIM_H
#define SKETCHYBAR_PREVIEW_SHIM_H

#include <CoreGraphics/CoreGraphics.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

/* Internal API of the preview shim.
   This header is private to the CSketchyBar target: it lives outside the
   public headers directory, so Swift never sees it. The public API is
   include/sketchybar_preview.h. */

/* The virtual display the preview draws for. The daemon asks the window
   server for the real displays; the preview has none, so it uses this id
   and the frame below. The frame is the default: sb_preview_set_display
   replaces it. */
#define PREVIEW_DISPLAY_ID 1
#define PREVIEW_DISPLAY_WIDTH 1440.0
#define PREVIEW_DISPLAY_HEIGHT 900.0

/* The scale of the backing bitmap. SketchyBar renders at a fixed scale of
   2.0 whatever the scale of the display is (src/surface.c:37). */
#define PREVIEW_DISPLAY_SCALE 2.0

/* The menu bar of the virtual display. The default is no menu bar at all:
   the menu bar of a real display is not part of the virtual one, and the
   fixed 480 x 25 display of the golden test is exactly the bar. The bar of
   the preview sits at the top of the display until a caller sets a menu
   bar with sb_preview_set_menu_bar. */
#define PREVIEW_MENU_BAR_HEIGHT 0.0

/* The one virtual space of the virtual display. */
#define PREVIEW_SPACE_ID 1

/* The space type the daemon reads from SkyLight. Type 4 is a fullscreen
   space, in which SketchyBar hides the bar. */
#define PREVIEW_SPACE_TYPE_FULLSCREEN 4

/* The geometry of the virtual display. The daemon reads it from the window
   server; the preview gets it from sb_preview_set_display. */
struct preview_display {
  double width;            /* points */
  double height;           /* points */
  double scale;            /* the scale of the backing bitmap */
  bool menu_bar_visible;   /* the menu bar of the display */
  double menu_bar_height;  /* points */
  bool has_notch;          /* the display is built-in and has a notch */
};

/* Sets the geometry of the virtual display. The scale is ignored: the
   preview keeps the fixed backing scale of 2.0. The menu bar is not
   touched: the caller sets it after the display. */
void preview_display_configure(double width, double height, double scale);

/* Puts the virtual display back to its default: the default frame, no
   menu bar and no notch. The preview calls it when a preview is created,
   so the display of the preview before it does not leak into it. */
void preview_display_reset(void);

/* Sets the menu bar of the virtual display. The daemon reads the menu bar
   of the display to push the bar down (src/bar.c:458-459, src/bar.c:478-479);
   the preview models it so that the bar of the preview has the same
   vertical origin as the bar of the machine. */
void preview_display_set_menu_bar(double height, bool visible);

/* Sets whether the virtual display is the built-in display of the machine.
   The daemon asks CoreGraphics (src/bar.c:201, src/bar.c:438), and the
   answer decides whether the notch of the bar applies. The preview has no
   window server, so the answer is a parameter of the virtual display. */
void preview_display_set_notch(bool has_notch);

/* Whether the virtual display has the notch of a built-in display. */
bool preview_display_has_notch(void);

/* The geometry of the virtual display. */
const struct preview_display* preview_display_config(void);

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

/* The environment of the child of the script runner, one "KEY=VALUE" per
   entry. The caller owns the array and releases every entry and the array
   itself with preview_free_environment. */
char** preview_build_environment(struct env_vars* env_vars);

/* Releases an environment of preview_build_environment: every entry and the
   array itself. */
void preview_free_environment(char** environment);

/* The outcome of a run of the scripts of the preview. The names carry
   OUTCOME, because PREVIEW_SCRIPT_TIMEOUT is the timeout of a script in
   seconds (`src/misc/helpers.h`). */
#define PREVIEW_SCRIPT_OUTCOME_OK      0
#define PREVIEW_SCRIPT_OUTCOME_TIMEOUT 1
#define PREVIEW_SCRIPT_OUTCOME_FAILED  2

/* The environment of the scripts of the preview.

   The shim directory comes first on the PATH of the child, so a script that
   calls `sketchybar` reaches the shim and not the live bar, and the sink
   variable carries the path of the file the shim writes to. The directories
   that hold a real sketchybar are removed from the PATH of the child. */
void preview_set_script_environment(const char* shim_directory,
                                    const char* sink_path,
                                    const char* log_directory);

/* The alias of the script that is forked next. The caller sets it before it
   forks, so the report of a script knows the item it belongs to. */
void preview_set_current_script(const char* alias);

/* Runs several scripts the way the daemon runs the script of an item: the
   same child, the same environment, the same timeout. Every child is
   forked first and the wait happens once, so the whole batch has one
   deadline and not one deadline per script.

   The arrays hold one alias and one script per entry, and the count is
   the number of entries. */
bool preview_run_scripts(char** aliases, char** scripts, size_t count);

/* The state of the items between two runs of the scripts. The item tree
   of the preview is rebuilt on every render and on every tick of the
   timer, so the counter of an item and the fact that it was on a bar are
   kept here and given back to the item when the tree is built again. The
   daemon keeps them in the item, which lives as long as the config
   (src/bar_item.c:126-133). */
uint32_t preview_item_counter_for(const char* alias);
bool preview_item_shown_for(const char* alias);
void preview_item_counter_store(const char* alias, uint32_t counter);
void preview_item_shown_store(const char* alias, bool shown);

/* Waits for the children of the scripts and reports what happened. */
void preview_wait_for_scripts(int timeout_milliseconds);

/* The outcome of the last run of the scripts. */
int preview_script_status(void);

/* The messages of the last run of the scripts, one per line. The pointer
   belongs to the runner and stays valid until the next run. */
const char* preview_script_messages(void);

#endif
