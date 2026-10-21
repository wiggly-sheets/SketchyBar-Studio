#ifndef SKETCHYBAR_PREVIEW_H
#define SKETCHYBAR_PREVIEW_H

#include <CoreGraphics/CoreGraphics.h>

/* The target builds with -fvisibility=hidden (makefile:1), so the exports
   need an explicit default visibility. */
#define SB_API __attribute__((visibility("default")))

typedef struct sb_preview sb_preview_t;

/* Creates a preview handle. Returns NULL when the vendored core cannot
   start. The caller owns the handle and releases it with
   sb_preview_destroy. */
SB_API sb_preview_t* sb_preview_create(void);

/* Releases a handle created by sb_preview_create. Passing NULL is a no-op. */
SB_API void sb_preview_destroy(sb_preview_t* preview);

/* The rest of the preview API (sb_preview_set_bar, sb_preview_set_default,
   sb_preview_add_item, sb_preview_set_item, sb_preview_set_display,
   sb_preview_render, sb_preview_release_image, sb_preview_item_rect and
   sb_preview_messages) is added in stage 2, together with the headless item
   tree it drives. See docs/bar-renderer/phase-2-headless-core.md. */

#endif
