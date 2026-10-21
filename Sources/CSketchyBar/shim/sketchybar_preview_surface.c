#include "surface.h"
#include "context.h"
#include "window.h"
#include "preview_shim.h"

/* The bitmap surface. The daemon pushes the surface into a CALayer of the
   window server; the preview keeps it in a bitmap context, and stage 4
   hands the image back to the caller.

   The scale of the bitmap is the scale of the virtual display. SketchyBar
   renders at a fixed scale of 2.0 whatever the scale of the screen is
   (src/surface.c:47), so the default of the shim is 2.0 as well. */

struct surface* surface_create(struct window* window) {
  struct surface* surface = malloc(sizeof(struct surface));
  if (!surface) return NULL;
  memset(surface, 0, sizeof(struct surface));

  surface->wid = window->id;
  surface->context = context_create(window->frame.size,
                                    preview_display_config()->scale   );
  return surface;
}

void surface_destroy(struct surface* surface) {
  if (!surface) return;
  if (surface->context) CGContextRelease(surface->context);
  free(surface);
}

void surface_resize(struct surface* surface, struct window* window) {
  if (!surface) return;
  if (surface->context) CGContextRelease(surface->context);
  surface->context = context_create(window->frame.size,
                                    preview_display_config()->scale   );
}

void surface_flush(struct surface* surface) {
  if (!surface || !surface->context) return;
  CGContextFlush(surface->context);
}
