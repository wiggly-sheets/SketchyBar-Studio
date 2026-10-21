#include "surface.h"
#include "context.h"
#include "window.h"

/* The bitmap surface. The daemon pushes the surface into a CALayer of the
   window server; the preview keeps it in a bitmap context, and stage 4
   hands the image back to the caller. */

struct surface* surface_create(struct window* window) {
  struct surface* surface = malloc(sizeof(struct surface));
  if (!surface) return NULL;
  memset(surface, 0, sizeof(struct surface));

  surface->wid = window->id;
  surface->context = context_create(window->frame.size, 2.0f);
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
  surface->context = context_create(window->frame.size, 2.0f);
}

void surface_flush(struct surface* surface) {
  if (!surface || !surface->context) return;
  CGContextFlush(surface->context);
}
