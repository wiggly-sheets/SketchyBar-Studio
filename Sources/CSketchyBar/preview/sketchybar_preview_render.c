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
}

/* Puts the bitmap of one window into the image of the bar. The origin is
   the place of the window in the image, in points. */
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
   says that it cannot show the item. */
static void preview_draw_placeholder(CGContextRef target, struct bar_item* item, struct bar* bar) {
  if (item->type != BAR_COMPONENT_ALIAS && item->type != BAR_COMPONENT_SPACE) return;
  if (item->num_windows < 1 || !item->windows[0]) return;

  struct window* window = item->windows[0];

  CGFloat side = PREVIEW_PLACEHOLDER_SIZE;
  if (side > window->frame.size.width) side = window->frame.size.width;
  if (side > bar->window.frame.size.height) side = bar->window.frame.size.height;
  if (side <= 0) return;

  CGRect box = CGRectMake(window->origin.x,
                           window->origin.y - bar->window.origin.y
                             + (bar->window.frame.size.height - side) / 2,
                           side,
                           side                       );

  CGContextSetRGBFillColor(target, 1.f, 1.f, 1.f, 0.25f);
  CGContextFillRect(target, box);
  CGContextSetRGBStrokeColor(target, 1.f, 1.f, 1.f, 0.5f);
  CGContextSetLineWidth(target, 1.f);
  CGContextStrokeRect(target, box);
}

/* The image of the bar. It is as wide as the display and as tall as the
   bar, and it starts at the top of the bar, so the margins of the bar
   stay empty as they are on the screen. */
static CGImageRef preview_compose(void) {
  if (g_bar_manager.bar_count == 0) return NULL;

  struct bar* bar = g_bar_manager.bars[0];
  const struct preview_display* display = preview_display_config();

  CGSize size = CGSizeMake(display->width, bar->window.frame.size.height);
  CGContextRef target = context_create(size, PREVIEW_DISPLAY_SCALE);
  if (!target) return NULL;

  preview_draw_window(target, &bar->window, CGPointMake(bar->window.origin.x, 0));

  for (uint32_t i = 0; i < g_bar_manager.bar_item_count; i++) {
    struct bar_item* item = g_bar_manager.bar_items[i];
    if (item->num_windows < 1 || !item->windows[0]) continue;

    struct window* window = item->windows[0];
    preview_draw_window(target,
                        window,
                        CGPointMake(window->origin.x,
                                    window->origin.y - bar->window.origin.y));
    preview_draw_placeholder(target, item, bar);
  }

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
