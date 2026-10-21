#ifndef SKETCHYBAR_PREVIEW_H
#define SKETCHYBAR_PREVIEW_H

#include <CoreGraphics/CoreGraphics.h>
#include <stddef.h>

/* The target builds with -fvisibility=hidden (makefile:1), so the exports
   need an explicit default visibility. */
#define SB_API __attribute__((visibility("default")))

/* The error codes of the preview API. Every function that returns an int
   returns SB_OK when it succeeded and one of the codes below when it
   failed. The codes are part of the contract and never change. */
#define SB_OK                     0  /* the call succeeded                    */
#define SB_ERR_INVALID_ARGUMENT   1  /* a required argument was NULL          */
#define SB_ERR_OUT_OF_MEMORY      2  /* an allocation failed                  */
#define SB_ERR_ITEM_NOT_FOUND     3  /* no item of the preview has that alias */
#define SB_ERR_ITEM_EXISTS        4  /* an item with that alias already exists*/
#define SB_ERR_PROPERTY_REJECTED  5  /* the vendored parser rejected the key  */
#define SB_ERR_SCRIPT_TIMEOUT     6  /* a script of an item ran too long      */
#define SB_ERR_SCRIPT_FAILED      7  /* a script of an item failed             */

/* The preview of one bar. The handle owns the model of the vendored core
   while it is alive: the items, the default item and the bar properties.
   The vendored core keeps that model in one global bar manager, so only one
   preview exists at a time. sb_preview_create returns NULL when another
   preview is alive. */
typedef struct sb_preview sb_preview_t;

/* Creates a preview handle. Returns NULL when the core cannot start: when
   the memory is gone, or when another preview is alive. The caller owns the
   handle and releases it with sb_preview_destroy.

   One preview exists at a time; creating a second returns NULL. The API is
   not thread-safe; call it from one queue. */
SB_API sb_preview_t* sb_preview_create(void);

/* Releases a handle created by sb_preview_create. Passing NULL is a no-op.
   The handle must be released exactly once. */
SB_API void sb_preview_destroy(sb_preview_t* preview);

/* Bar level: key is a SketchyBar bar property, e.g. "position", "margin".
   The value is the value of the property, e.g. "10". */
SB_API int  sb_preview_set_bar(sb_preview_t* preview, const char* key, const char* value);

/* Default-item level: key is a SketchyBar item property, e.g. "icon.font".
   These are the properties of the DEFAULT ITEM, not of the bar. They are a
   snapshot taken when an item is created, so they must be set BEFORE the
   items are added. See the defaults contract below. */
SB_API int  sb_preview_set_default(sb_preview_t* preview, const char* key, const char* value);

/* Item level: alias, type, position and argument first, then one property
   at a time. The four arguments are the four arguments of the add command
   of the daemon: "add <type> <alias> <position> [<argument>]"
   (src/message.c:180-256).

   The alias is the name of the item, e.g. "apple". The type is the type of
   the add command, e.g. "item", "alias" or "space" (src/message.c:196). A
   type the daemon does not know makes the item a plain item, and the answer
   says so.

   The position is the position of the add command, e.g. "left" or "right".
   It is not optional: the daemon removes an item whose add position is
   missing or illegal (src/message.c:202-208), and so does the preview. The
   item is then gone, and the answer carries the message of the daemon.

   The argument is the trailing argument of the add command: the width of a
   graph and of a slider, and the diameter of a ring (src/message.c:218-256).
   The other types ignore it. A ring needs a diameter that is positive, and
   the daemon removes the item when it is not (src/message.c:236-248). A
   graph needs a width, and the daemon crashes when it has none: it draws
   the graph and divides by its width (src/graph.c:24). The preview removes
   the item and says so, so the process of the app survives.

   An alias item and a space item show the content of the window server,
   which the preview does not have. They keep a placeholder of a fixed size
   (see the contract of the placeholders below). */
SB_API int  sb_preview_add_item(sb_preview_t* preview, const char* alias,
                                const char* type, const char* position,
                                const char* argument);
SB_API int  sb_preview_set_item(sb_preview_t* preview, const char* alias,
                                const char* key, const char* value);

/* The virtual display the bar is laid out for. The width and the height are
   in POINTS. The scale is the scale of the backing bitmap, which is fixed at
   2.0 in SketchyBar and is not the scale of the screen. The preview keeps
   that fixed scale of 2.0 and ignores the argument.

   The call rebuilds the bar of the preview, so its frame follows the new
   display (src/bar.c:516-522).

   The C API has no default for the width: the caller always passes one.
   The default belongs to the caller, because the width of the target
   display is a property of the machine, not of the vendored core. The
   Swift wrapper (Sources/SketchyBarStudio/Support/SketchyBarPreviewC.swift)
   derives it from the target NSScreen and passes it down. The C default,
   used when the caller never sets a display, is 1440 x 900 points. */
SB_API int  sb_preview_set_display(sb_preview_t* preview,
                                    double widthPoints, double heightPoints, double scale);

/* The height of the menu bar above the bar, in POINTS. 0 means there is no
   menu bar and the bar starts at the top of the display. The call comes
   after sb_preview_set_display: the menu bar does not change the geometry
   of the display. The menu bar moves the bar down, so it has to be set
   before the render. */
SB_API int  sb_preview_set_menu_bar(sb_preview_t* preview, double heightPoints);

/* Whether the virtual display is the built-in display of the machine, and
   so has the notch of a notched Mac.

   The daemon asks CoreGraphics whether the display is built-in, and the
   answer decides whether the notch of the bar applies: the notch width
   moves the items of the centre and of the right (src/bar.c:200-222), and
   the notch offset and the notch height move the bar itself
   (src/bar.c:437-440). The preview has no window server, so the answer is
   a parameter of the virtual display. The width, the offset and the height
   of the notch are the bar properties "notch_width", "notch_offset" and
   "notch_display_height", exactly as in the daemon.

   The call comes after sb_preview_set_display. Zero means the virtual
   display has no notch, which is the default. */
SB_API int  sb_preview_set_notch(sb_preview_t* preview, int hasNotch);

/* Renders the bar into a bitmap and returns a retained CGImage. The caller
   owns it and releases it with sb_preview_release_image.

   The call lays the bar out with the code of the daemon
   (src/bar_manager.c:424-447) and draws it, so the rectangles of the items
   and the image are the same layout.

   The image is the FRAME OF THE BAR, in the fixed backing scale of 2.0: a
   bar of 480 x 25 points gives an image of 960 x 50 pixels. The origin of
   the image is the origin of the bar in the coordinate system of the
   display, so the margins of the bar stay empty as they are on the screen.
   The bar draws itself into the image, and so does every item, at the place
   the layout gave it. The image is the frame of the bar and not the frame
   of the display, so a bar on the left or on the right of the display has
   the shape of that bar.

   The image is NULL when the preview has no bar, or when the bitmap could
   not be created. */
SB_API CGImageRef sb_preview_render(sb_preview_t* preview);

/* Releases an image that sb_preview_render returned. Passing NULL is a
   no-op. */
SB_API void sb_preview_release_image(CGImageRef image);

/* The origin and size of one item, in POINTS, after layout.

   The rectangle is the frame of the window of the item, in the coordinate
   system of the virtual display: it is the same value as the
   "bounding_rects" of `sketchybar --query <item>` (src/bar_item.c:1065-1079).
   An item that the bar does not draw keeps the rectangle of the nirvana
   point, like it does on the screen.

   The call lays the bar out when the item has no window yet, so the
   rectangle is the one of the bar even when the render did not run. */
SB_API int sb_preview_item_rect(sb_preview_t* preview, const char* alias,
                                CGRect* outRect);

/* The origin and size of the window of the bar, in POINTS.

   The rectangle is the frame of the bar in the coordinate system of the
   virtual display, so it is in the same space as the rectangle of
   sb_preview_item_rect: the rectangle of an item lies inside it, shifted
   by the height of the menu bar when the virtual display has one.

   The image of sb_preview_render is that rectangle: the origin of the
   image is the origin of the bar. The mapping of a rectangle onto the
   image is

     image_x_pt = rect.origin.x - barFrame.origin.x,
     image_y_pt = rect.origin.y - barFrame.origin.y,

   and the pixel is the point times 2, because the backing scale of the
   bitmap is the fixed scale of 2.0 of SketchyBar.

   The call lays the bar out when the bar has no window yet, so the frame is
   the one of the bar even when the render did not run. */
SB_API int sb_preview_bar_frame(sb_preview_t* preview, CGRect* outFrame);

/* Messages the vendored code produced, one per line. The returned pointer is
   owned by the preview: it stays valid until the next call that can produce
   a message, and until sb_preview_destroy. The caller must not free it. */
SB_API const char* sb_preview_messages(sb_preview_t* preview);

/* The environment of the scripts of the preview.

   The scripts of the items run inside the preview, in a child process, the
   way the daemon runs them (src/bar_item.c:166-168). A script that calls
   `sketchybar` must never reach the live bar of the user, so the child gets
   a PATH whose first entry is the directory of the shim, and the shim
   writes to the sink file instead of talking to the daemon.

   The shim directory is the directory that holds the shim, the sink path is
   the file the shim writes to, and the log directory is the directory that
   holds the standard error of every script. All three are in a directory of
   their own, and the preview removes that directory when the render is
   done.

   The setting is global, because the runner of the scripts is global: the
   children of the scripts are tracked in one place. The call comes before
   the call that runs the scripts. */
SB_API int sb_preview_set_script_environment(const char* shim_directory,
                                              const char* sink_path,
                                              const char* log_directory);

/* Runs the script of every item of the preview that has one.

   The scripts run the way the daemon runs them: the routine of the item
   and nothing else (src/bar_manager.c:554), which is
   bar_item_update(item, NULL, false, NULL). The gate of the daemon
   decides whether a script runs at all: `updates = false` never runs it,
   an item without `update_freq` runs it only on an event, and
   `updates = when_shown` runs it only while the item is on a bar
   (src/bar_item.c:127-139).

   The child gets the environment of the item itself: the name of the
   item, the variables of the item and the sender (src/bar_item.c:142-161).
   The environment of the child is the environment of the shim, so the
   calls the script makes reach the shim.

   The call waits for the children. A script that runs longer than the
   timeout of the preview is stopped, and the answer is
   SB_ERR_SCRIPT_TIMEOUT. A script that fails answers
   SB_ERR_SCRIPT_FAILED. The messages of the run say which item failed and
   why: sb_preview_script_messages has them.

   The counter of an item decides when its script runs, exactly as in the
   daemon (src/bar_item.c:132-133). The preview rebuilds its item tree on
   every render, so the counter of an item is kept between the trees.

   The messages of the run are separate from the messages of the properties,
   because the properties of an item are read after the scripts ran, and
   that read clears the messages of the properties. */
SB_API int sb_preview_run_item_scripts(sb_preview_t* preview);

/* Runs several scripts, by their text, the way the daemon runs the script
   of an item.

   The aliases and the scripts hold one entry per script, and the count is
   the number of the entries. Every child is forked first and the call
   waits for all of them once, so the whole batch has one deadline: N
   scripts that hang cost one timeout and not N of them.

   The scripts of this route run with the name of the item and the sender
   only. The route that runs the scripts of the items themselves,
   sb_preview_run_item_scripts, gives the child the environment of the
   item.

   The call answers the same codes as sb_preview_run_item_scripts. */
SB_API int sb_preview_run_scripts(const char* const* aliases,
                                   const char* const* scripts,
                                   size_t count);

/* The script of the item with that alias, or NULL when the item has none.

   The script can be one the config does not set: a space item gets the
   script of the daemon (src/bar_item.c:428-431). The pointer belongs to
   the item of the preview and must not be freed. */
SB_API const char* sb_preview_item_script(sb_preview_t* preview, const char* alias);

/* The messages of the last run of the scripts, one per line. The returned
   pointer belongs to the runner: it stays valid until the next run of the
   scripts. The caller must not free it. */
SB_API const char* sb_preview_script_messages(void);

/* The contract of the defaults.

   sb_preview_set_default writes to the default item of the preview, exactly
   like `sketchybar --default` does (src/misc/help.h:12-13, src/message.c:335).
   The default item is inherited when an item is created (src/bar_manager.c:463,
   src/bar_item.c:68, src/bar_item.c:883-933), so every call to
   sb_preview_set_default must come before the first sb_preview_add_item. A
   default set after an item exists never reaches that item, and there is no
   way to reach an existing item afterwards through this API.

   The key "reset" empties the default item again, like `--default reset`
   does (src/bar_item.c:1363).

   The contract of the points and the pixels.

   Every rectangle the API reports is in POINTS. The backing bitmap is
   rendered at the fixed scale of 2.0, which is what SketchyBar itself uses
   (src/surface.c:37, src/surface.c:47), independent of the scale of the
   display. The bitmap is therefore twice the size of the point geometry:
   the image of sb_preview_render is the frame of the bar in points, so its
   pixel size is the width of the bar times 2 by the height of the bar
   times 2.

   The contract of the placeholders.

   An alias item draws a captured menu bar item (src/alias.c:206-223) and a
   space item draws a captured space (src/image.c:67-76). Both need the
   window server, and the preview has none. Such an item keeps a box of 16
   points. That width is a value CHOSEN BY THIS PROJECT: the real width of
   an alias item is the width of the captured image of the menu bar item,
   and a space is as wide as the captured space, so the preview cannot know
   it. The render draws the box into the bitmap of the item itself, so the
   item keeps its place on the bar and an export of the item alone shows
   the box too. A width of the config wins over the placeholder.

   The app warns about such an item before it reaches the preview: the
   parsers of the app report the type the preview cannot show
   (PreviewWarning.unsupportedType), and the app does not send it to the
   preview. The type of sb_preview_add_item is there for the differential
   test of stage 8.

   The contract of the messages.

   The vendored parsers report a rejected property by writing a message that
   starts with "[!]" into the reply stream of the parser. The API collects
   that text, hands it to sb_preview_messages and answers
   SB_ERR_PROPERTY_REJECTED. The message stays readable after the call that
   produced it, until the next call that can produce a message.

   The test-only accessors below are not part of the preview API. The app
   never calls them. They exist so that the tests of the preview core can
   read the state of the vendored model without reaching into it: the tests
   call them directly through this header. */

/* The fixed width of an item, or -1 when the item has none or is unknown. */
SB_API int sb_preview_test_item_width(sb_preview_t* preview, const char* alias);

/* The left padding of the background of an item, or -1 when the item is
   unknown. */
SB_API int sb_preview_test_item_padding_left(sb_preview_t* preview, const char* alias);

/* The serialized form of an item, the same text `sketchybar --query <item>`
   answers with. The caller owns the string and releases it with free().
   It is NULL when no item has that alias.

   The text is NOT always valid JSON: the vendored code writes the text of
   a label without escaping it (src/text.c:1027), so a label that holds a
   quote or a newline breaks a JSON parser. The daemon has the same
   defect. */
SB_API char* sb_preview_test_item_serialize(sb_preview_t* preview, const char* alias);

/* The bitmap of an item, in the scale of the backing bitmap. The caller
   owns the image and releases it with sb_preview_release_image. It is NULL
   when no item has that alias, or when the item has no window yet. */
SB_API CGImageRef sb_preview_test_item_image(sb_preview_t* preview, const char* alias);

/* The environment the child of the script runner receives, one "KEY=VALUE"
   per line. The caller owns the string and releases it with free(). */
SB_API char* sb_preview_test_child_environment(void);

#endif
