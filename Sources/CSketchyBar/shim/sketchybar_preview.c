#include <stdlib.h>
#include "sketchybar_preview.h"
#include "bar_item.h"

/* The preview handle. Stage 1 proves the link: the item tree, the messages
   and the render path arrive in stage 2 and stage 4. */

struct sb_preview {
  struct bar_item default_item;
};

sb_preview_t* sb_preview_create(void) {
  sb_preview_t* preview = malloc(sizeof(sb_preview_t));
  if (!preview) return NULL;
  memset(preview, 0, sizeof(sb_preview_t));

  // The item model of the vendored core. Stage 2 fills it with the items
  // of the preview.
  bar_item_init(&preview->default_item, NULL);

  return preview;
}

void sb_preview_destroy(sb_preview_t* preview) {
  if (!preview) return;
  // The item owns heap memory as soon as it has a name or a script, so it
  // is destroyed before the handle goes away.
  bar_item_destroy(&preview->default_item, false);
  free(preview);
}
