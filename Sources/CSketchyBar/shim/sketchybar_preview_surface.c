#include "surface.h"
#include "context.h"
#include "window.h"
#include "preview_shim.h"
#include <math.h>

/* The bitmap surface. The daemon pushes the surface into a CALayer of the
   window server; the preview keeps it in a bitmap context, and stage 4
   hands the image back to the caller.

   The scale of the bitmap is the scale of the virtual display. SketchyBar
   renders at a fixed scale of 2.0 whatever the scale of the screen is
   (src/surface.c:47), so the default of the shim is 2.0 as well. */

/* The size of the bitmap of a window.

   An item with a width of zero and no text has a frame of no size, and
   context_create answers NULL for such a size (src/context.c:6-8). The
   draw of the bar would then call CoreGraphics with a NULL context
   (src/bar.c:188), so the preview keeps a bitmap of one point, which
   holds nothing. */
static CGSize surface_size(CGSize size) {
  // A size that is not finite, or that is huge, would reach CoreGraphics
  // as an undefined (size_t) cast and leave a NULL context behind, which
  // the vendored draw code dereferences. A width from a config can be
  // arbitrary, so the preview clamps to a bitmap it can hold.
  if (!isfinite(size.width) || size.width < 1) size.width = 1;
  if (!isfinite(size.height) || size.height < 1) size.height = 1;
  /* The display width may be 20,000 points, so the width is not clamped to
     a small constant. The area is bounded instead: a bitmap of a bar is
     wide and short, and a pathological window cannot allocate a bitmap of
     many gigabytes. 4,000,000 points is 64 MB at the fixed scale of 2.0. */
  const CGFloat maximumWidth = 20000;
  const CGFloat maximumArea = 4000000;
  if (size.width > maximumWidth) size.width = maximumWidth;
  if (size.height > maximumWidth) size.height = maximumWidth;
  CGFloat area = size.width * size.height;
  if (area > maximumArea) {
    CGFloat factor = sqrt(maximumArea / area);
    size.width *= factor;
    size.height *= factor;
  }
  return size;
}

struct surface* surface_create(struct window* window) {
  struct surface* surface = malloc(sizeof(struct surface));
  if (!surface) return NULL;
  memset(surface, 0, sizeof(struct surface));

  surface->wid = window->id;
  surface->context = context_create(surface_size(window->frame.size),
                                    preview_display_config()->scale   );
  /* The vendored draw code does not check the context. When the bitmap
     cannot be created, a one-point context keeps the draw harmless. */
  if (!surface->context) {
    surface->context = context_create(CGSizeMake(1, 1),
                                      preview_display_config()->scale);
  }
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
  surface->context = context_create(surface_size(window->frame.size),
                                    preview_display_config()->scale   );
  if (!surface->context) {
    surface->context = context_create(CGSizeMake(1, 1),
                                      preview_display_config()->scale);
  }
}

void surface_flush(struct surface* surface) {
  if (!surface || !surface->context) return;
  CGContextFlush(surface->context);
}
