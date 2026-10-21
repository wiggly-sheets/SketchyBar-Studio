#include "window.h"
#include "surface.h"
#include "misc/helpers.h"

/* The in-memory window record. The daemon asks the window server for a
   window and pushes the surface into a CALayer; the preview keeps the
   record in memory and draws it into a bitmap surface. */

struct window* window_create() {
  struct window* window = malloc(sizeof(struct window));
  if (!window) return NULL;
  memset(window, 0, sizeof(struct window));
  window_init(window);
  return window;
}

void window_init(struct window* window) {
  window->context = NULL;
  window->surface = NULL;
  window->parent = NULL;
  window->frame = CGRectNull;
  window->id = 0;
  window->origin = CGPointZero;
  window->needs_move = false;
  window->needs_resize = false;
  window->order_mode = W_ABOVE;
  window->refc = 1;
}

void window_destroy(struct window* window) {
  if (!window) return;
  if (--window->refc > 0) return;
  window_close(window);
  free(window);
}

void window_open(struct window* window, CGRect frame) {
  window->origin = frame.origin;
  window->frame.origin = CGPointZero;
  window->frame.size = frame.size;
  window->id = 1;

  window->surface = surface_create(window);
  window->needs_move = false;
  window->needs_resize = false;
}

void window_close(struct window* window) {
  if (!window) return;
  if (window->surface) {
    surface_destroy(window->surface);
    window->surface = NULL;
  }
  window_clear(window);
}

void window_clear(struct window* window) {
  window->context = NULL;
  window->surface = NULL;
  window->parent = NULL;
  window->id = 0;
  window->origin = CGPointZero;
  window->frame = CGRectNull;
  window->needs_move = false;
  window->needs_resize = false;
  window->refc = 1;
}

void window_flush(struct window* window) {
  if (!window) return;
  surface_flush(window->surface);
}

void windows_freeze() {
}

void windows_unfreeze() {
}

void window_set_frame(struct window* window, CGRect frame) {
  if (window->needs_move
      || !CGPointEqualToPoint(window->origin, frame.origin)) {
    window->needs_move = true;
    window->origin = frame.origin;
  }

  if (window->needs_resize
      || !CGSizeEqualToSize(window->frame.size, frame.size)) {
    window->needs_resize = true;
    window->frame.size = frame.size;
  }
}

void window_move(struct window* window, CGPoint point) {
  window->origin = point;
}

bool window_apply_frame(struct window* window, bool forced) {
  if (window->needs_resize || forced) {
    surface_resize(window->surface, window);
    window->needs_move = false;
    window->needs_resize = false;
    return true;
  } else if (window->needs_move) {
    window->needs_move = false;
    return false;
  }
  return false;
}

void window_send_to_space(struct window* window, uint64_t dsid) {
}

void window_set_blur_radius(struct window* window, uint32_t blur_radius) {
}

void window_disable_shadow(struct window* window) {
}

void window_set_level(struct window* window, uint32_t level) {
}

void window_order(struct window* window, struct window* parent, int mode) {
  window->parent = parent;
  if (mode != W_OUT) window->order_mode = mode;
}

void window_assign_mouse_tracking_area(struct window* window, CGRect rect) {
}

CGImageRef window_capture(struct window* window, bool* disabled) {
  /* The preview has no window server, so there is nothing to capture. The
     alias item falls back to its placeholder. */
  if (disabled) *disabled = true;
  return NULL;
}
