#ifndef SKETCHYBAR_PREVIEW_H
#define SKETCHYBAR_PREVIEW_H

#include <CoreGraphics/CoreGraphics.h>

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

/* Item level: alias and type first, then one property at a time. The alias
   is the name of the item, e.g. "apple". The type is the type of the add
   command of the daemon, e.g. "item", "alias" or "space"
   (src/message.c:196). A type the daemon does not know makes the item a
   plain item, and the answer says so.

   An alias item and a space item show the content of the window server,
   which the preview does not have. They keep a placeholder of a fixed size
   (see the contract of the placeholders below). */
SB_API int  sb_preview_add_item(sb_preview_t* preview, const char* alias,
                                const char* type);
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

/* Renders the bar into a bitmap and returns a retained CGImage. The caller
   owns it and releases it with sb_preview_release_image.

   The call lays the bar out with the code of the daemon
   (src/bar_manager.c:424-447) and draws it, so the rectangles of the items
   and the image are the same layout.

   The image is as WIDE AS THE DISPLAY and as TALL AS THE BAR, in the fixed
   backing scale of 2.0: a display of 480 x 25 points gives an image of
   960 x 50 pixels. The image starts at the top of the bar, so the margins
   of the bar stay empty as they are on the screen: the origin of the image
   in the coordinate system of the display is (0, the top of the bar). The
   bar draws itself into the image, and so does every item, at the place
   the layout gave it.

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

/* Messages the vendored code produced, one per line. The returned pointer is
   owned by the preview: it stays valid until the next call that can produce
   a message, and until sb_preview_destroy. The caller must not free it. */
SB_API const char* sb_preview_messages(sb_preview_t* preview);

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
   the image of sb_preview_render is the width of the display and the
   height of the bar in points, so its pixel size is the width of the
   display times 2 by the height of the bar times 2.

   The contract of the placeholders.

   An alias item draws a captured menu bar item (src/alias.c:206-223) and a
   space item draws a captured space (src/image.c:67-76). Both need the
   window server, and the preview has none. Such an item keeps a box of 16
   points, the size of a menu bar extra, and the render draws the box, so
   the item keeps its place on the bar. A width of the config wins over the
   placeholder. The app warns that the preview cannot show the item
   (PreviewWarning.unsupportedType).

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

/* The environment the child of the script runner receives, one "KEY=VALUE"
   per line. The caller owns the string and releases it with free(). */
SB_API char* sb_preview_test_child_environment(void);

#endif
