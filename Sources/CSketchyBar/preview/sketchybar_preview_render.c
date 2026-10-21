#include <stdlib.h>

#include "sketchybar_preview.h"

#include "bar.h"
#include "bar_item.h"
#include "bar_manager.h"
#include "context.h"
#include "misc/helpers.h"
#include "preview_internal.h"
#include "surface.h"
#include "window.h"

/* The render of the preview.

   The daemon draws the bar in two steps: the background of the bar goes
   into the window of the bar and every item goes into its own window
   (src/bar.c:140-198). The preview has no window server, so the windows
   are records in memory (shim/sketchybar_preview_window.c) and their
   surfaces are bitmaps (shim/sketchybar_preview_surface.c).

   This file lays the bar out with the code of the daemon and puts the
   bitmaps of the windows together into one image, the way the screen
   shows the windows of the bar. */

/* The layout of the bar. The daemon lays the bar out when it refreshes it
   (src/bar_manager.c:424-447): the bounds of the bar, the draw of the bar
   and the order of the item windows. The preview does the same. */
static void preview_layout(void) {
  if (g_bar_manager.bar_count == 0) {
    /* The bar of the preview is built when the display is set. A caller
       that never sets a display gets the default display of the shim. */
    bar_manager_reset(&g_bar_manager);
  }

  /* The daemon redraws the background of the bar when the bar needs an
     update (src/bar.c:146-154). The preview draws a new image on every
     call, so the background is always redrawn. */
  g_bar_manager.bar_needs_update = true;

  bar_manager_refresh(&g_bar_manager, true);

  /* The draw tells which items are on a bar (src/bar.c:169), and the
     daemon reads that state when it updates an item
     (src/bar_item.c:115, :135-137). The preview rebuilds its item tree,
     so the state goes into the registry of the shim and comes back into
     the item of the next tree. */
  for (uint32_t i = 0; i < g_bar_manager.bar_item_count; i++) {
    struct bar_item* item = g_bar_manager.bar_items[i];
    if (!item || !item->name) continue;
    preview_item_shown_store(item->name, bar_item_is_shown(item));
  }
}

/* Puts the bitmap of one window into the image of the bar. The origin is
   the place of the window in the image, in points. The image is in the
   coordinate system of CoreGraphics, so the y of the origin is the bottom
   of the window in the image. */
static void preview_draw_window(CGContextRef target, struct window* window, CGPoint origin) {
  if (!window || !window->surface || !window->surface->context) return;

  CGImageRef image = CGBitmapContextCreateImage(window->surface->context);
  if (!image) return;

  /* The size of the image is the size of the window in points: the bitmap
     of the window is at the fixed scale of 2.0 (src/surface.c:47). */
  CGRect target_rect = CGRectMake(origin.x,
                                   origin.y,
                                   CGImageGetWidth(image) / PREVIEW_DISPLAY_SCALE,
                                   CGImageGetHeight(image) / PREVIEW_DISPLAY_SCALE);

  CGContextDrawImage(target, target_rect, image);
  CGImageRelease(image);
}

/* The placeholder of the items that need the window server.

   An alias item draws a captured menu bar item (src/alias.c:206-223) and a
   space item draws a captured space (src/image.c:67-76). The preview has
   no window server, so the item keeps a box of a fixed size and the app
   says that it cannot show the item.

   The box is drawn into the bitmap of the item itself and not into the
   image of the bar, so an export of the item alone shows the box too. The
   bitmap of the item is in the coordinate system of CoreGraphics, so the
   box starts at the left of the item and is centred in its height. */
static void preview_draw_placeholder(struct bar_item* item) {
  if (item->type != BAR_COMPONENT_ALIAS && item->type != BAR_COMPONENT_SPACE) return;
  if (item->num_windows < 1 || !item->windows[0]) return;

  struct window* window = item->windows[0];
  if (!window->surface || !window->surface->context) return;

  CGFloat side = PREVIEW_PLACEHOLDER_SIZE;
  if (side > window->frame.size.width) side = window->frame.size.width;
  if (side > window->frame.size.height) side = window->frame.size.height;
  if (side <= 0) return;

  CGRect box = CGRectMake(0,
                           (window->frame.size.height - side) / 2,
                           side,
                           side                       );

  CGContextRef context = window->surface->context;
  CGContextSetRGBFillColor(context, 1.f, 1.f, 1.f, 0.25f);
  CGContextFillRect(context, box);
  CGContextSetRGBStrokeColor(context, 1.f, 1.f, 1.f, 0.5f);
  CGContextSetLineWidth(context, 1.f);
  CGContextStrokeRect(context, box);
}

/* The depth of a window in the order of the daemon.

   The daemon orders the windows of the items when it refreshes the bar
   (src/bar.c:82-111, src/bar_manager.c:441): every item is above the
   window before it, and a group is below the first window. The preview
   has no window server, so the shim keeps the parent and the order of
   every window (shim/sketchybar_preview_window.c) and the composition
   draws the items in that order. The depth is the number of windows a
   window is above, so a bigger depth is nearer the top. */
static int preview_window_depth(struct window* window) {
  int depth = 0;
  struct window* current = window;

  /* The chain of the parents is short, but a group can be its own parent
     (src/bar.c:100-104), so the walk has a bound. */
  for (int guard = 0; current && guard < 64; guard++) {
    struct window* parent = current->parent;
    if (!parent || parent == current) break;

    depth += (current->order_mode == W_BELOW) ? -1 : 1;
    current = parent;
  }

  return depth;
}

/* One item of the composition: the item and the depth of its window. */
struct preview_item {
  struct bar_item* item;
  int depth;
};

/* The items of the bar, in the order the daemon draws them. The order of
   the items is the order of the daemon when the depths are the same,
   because the daemon orders the windows of the items in the order of the
   items. */
static void preview_sort_items(struct preview_item* items, uint32_t count) {
  for (uint32_t i = 1; i < count; i++) {
    struct preview_item current = items[i];
    uint32_t j = i;

    while (j > 0 && items[j - 1].depth > current.depth) {
      items[j] = items[j - 1];
      j--;
    }
    items[j] = current;
  }
}

/* The image of the bar. It is the frame of the bar, so the margins of the
   bar stay empty as they are on the screen, and a bar on the left or on
   the right of the display has the shape of that bar. */
static CGImageRef preview_compose(void) {
  if (g_bar_manager.bar_count == 0) return NULL;

  struct bar* bar = g_bar_manager.bars[0];

  CGSize size = bar->window.frame.size;
  CGContextRef target = context_create(size, PREVIEW_DISPLAY_SCALE);
  if (!target) return NULL;

  /* The bar draws itself into the image: the image is its frame. */
  preview_draw_window(target, &bar->window, CGPointZero);

  uint32_t count = g_bar_manager.bar_item_count;
  struct preview_item* items = count ? malloc(count * sizeof(struct preview_item)) : NULL;
  if (count && !items) {
    CGContextRelease(target);
    return NULL;
  }

  uint32_t drawn = 0;
  for (uint32_t i = 0; i < count; i++) {
    struct bar_item* item = g_bar_manager.bar_items[i];
    if (item->num_windows < 1 || !item->windows[0]) continue;

    items[drawn].item = item;
    items[drawn].depth = preview_window_depth(item->windows[0]);
    drawn++;
  }

  preview_sort_items(items, drawn);

  for (uint32_t i = 0; i < drawn; i++) {
    struct bar_item* item = items[i].item;
    struct window* window = item->windows[0];

    /* The placeholder belongs to the item, so it is drawn into the bitmap
       of the item and not into the image of the bar. */
    preview_draw_placeholder(item);

    /* The origin of the window of the item is the top left of the item in
       the coordinate system of the display, where the y grows downwards.
       The image of the bar grows upwards, so the bottom of the item is
       the distance from the bottom of the bar to the bottom of the item. */
    preview_draw_window(target,
                        window,
                        CGPointMake(window->origin.x - bar->window.origin.x,
                                    bar->window.origin.y
                                      + bar->window.frame.size.height
                                      - window->origin.y
                                      - window->frame.size.height));
  }

  free(items);

  CGImageRef image = CGBitmapContextCreateImage(target);
  CGContextRelease(target);
  return image;
}

CGImageRef sb_preview_render(sb_preview_t* preview) {
  if (!preview) return NULL;

  preview_layout();
  return preview_compose();
}

void sb_preview_release_image(CGImageRef image) {
  if (!image) return;
  CGImageRelease(image);
}

int sb_preview_item_rect(sb_preview_t* preview, const char* alias, CGRect* outRect) {
  if (!preview || !alias || !outRect) return SB_ERR_INVALID_ARGUMENT;

  struct bar_item* item = preview_find_item(alias);
  if (!item) return SB_ERR_ITEM_NOT_FOUND;

  if (item->num_windows < 1 || !item->windows[0]) {
    /* The item has no window yet, so the bar has not been laid out. The
       layout builds the window of every item. */
    preview_layout();
  }

  if (item->num_windows < 1 || !item->windows[0]) return SB_ERR_ITEM_NOT_FOUND;

  /* The frame of the window of the item, in points. It is the same value
     as the "bounding_rects" of `sketchybar --query <item>`
     (src/bar_item.c:1065-1079). */
  struct window* window = item->windows[0];
  *outRect = CGRectMake(window->origin.x,
                        window->origin.y,
                        window->frame.size.width,
                        window->frame.size.height);
  return SB_OK;
}

int sb_preview_bar_frame(sb_preview_t* preview, CGRect* outFrame) {
  if (!preview || !outFrame) return SB_ERR_INVALID_ARGUMENT;

  if (g_bar_manager.bar_count == 0) {
    /* The bar of the preview is built when the display is set. A caller
       that never sets a display gets the default display of the shim. */
    preview_layout();
  }

  if (g_bar_manager.bar_count == 0) return SB_ERR_ITEM_NOT_FOUND;

  /* The frame of the window of the bar, in points. It is in the same
     coordinate system as the rectangle of an item, so the rectangle of an
     item lies inside it. */
  struct bar* bar = g_bar_manager.bars[0];
  *outFrame = CGRectMake(bar->window.origin.x,
                         bar->window.origin.y,
                         bar->window.frame.size.width,
                         bar->window.frame.size.height);
  return SB_OK;
}
