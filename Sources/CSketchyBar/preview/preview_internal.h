#ifndef SKETCHYBAR_PREVIEW_INTERNAL_H
#define SKETCHYBAR_PREVIEW_INTERNAL_H

#include <stdbool.h>
#include <stdio.h>

#include "bar_item.h"
#include "bar_manager.h"
#include "preview_shim.h"

/* The size of the placeholder of the items that need the window server, in
   points. An alias item shows a captured menu bar item and a space item
   shows a captured space. The preview has no window server, so the item
   keeps a box of this size instead of the content it cannot show. */
#define PREVIEW_PLACEHOLDER_SIZE 16

/* The state of the preview. The vendored core keeps its model in the global
   bar manager of the shim, so the preview owns that global for the lifetime
   of the handle and the handle itself only holds the messages. */
struct sb_preview {
  char* messages;
};

/* The lifecycle of the global bar manager of the preview. */
bool preview_bar_manager_init(void);
void preview_bar_manager_destroy(void);

/* The bar domain of the dropped src/message.c. The daemon routes the
   properties of the bar through it (src/message.c:338-464); the preview
   routes them through this function. */
bool preview_parse_bar_set_message(FILE* rsp, char* message);

/* The item tree of the preview. Returns NULL when no item has that alias. */
struct bar_item* preview_find_item(const char* alias);

/* Empties the default item again, like `--default reset` does. */
void preview_reset_default_item(void);

#endif
