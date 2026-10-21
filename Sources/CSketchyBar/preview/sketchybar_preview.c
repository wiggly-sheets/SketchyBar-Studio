#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sketchybar_preview.h"

#include "bar_item.h"
#include "bar_manager.h"
#include "misc/helpers.h"
#include "preview_internal.h"

/* The preview API. The item tree is the tree of the vendored core: the
   items live in the global bar manager of the shim, the default item is
   its default_item, and the bar properties are its own.

   One preview at a time. The vendored core keeps its model in one global,
   so a second preview would overwrite the items of the first one. */

/* The error codes of the API live in include/sketchybar_preview.h. */

/* The live handle. The vendored core keeps its model in one global, so the
   model belongs to the handle that created it. */
static sb_preview_t* g_preview = NULL;

static char* preview_copy(const char* text) {
  size_t length = strlen(text);
  char* copy = malloc(length + 1);
  if (!copy) return NULL;
  memcpy(copy, text, length + 1);
  return copy;
}

/* Builds the message the vendored parsers expect: the key, a NUL, the
   value, a NUL and a final NUL. That is the format of the key/value pairs
   of the daemon (src/message.c:468-478, src/misc/helpers.h:149). */
static char* preview_build_message(const char* key, const char* value) {
  size_t key_length = strlen(key);
  size_t value_length = value ? strlen(value) : 0;
  char* message = malloc(key_length + value_length + 3);
  if (!message) return NULL;

  memcpy(message, key, key_length);
  message[key_length] = '\0';
  if (value_length) memcpy(message + key_length + 1, value, value_length);
  message[key_length + 1 + value_length] = '\0';
  message[key_length + 2 + value_length] = '\0';
  return message;
}

static void preview_clear_messages(sb_preview_t* preview) {
  if (!preview->messages) return;
  free(preview->messages);
  preview->messages = NULL;
}

/* The vendored parsers report a rejected property by writing a message that
   starts with "[!]" into the reply stream (src/bar_item.c:1366,
   src/bar_item.c:1368). */
static bool preview_messages_have_error(const char* messages) {
  if (!messages) return false;
  const char* cursor = messages;
  while (*cursor) {
    if (strncmp(cursor, "[!]", 3) == 0) return true;
    const char* newline = strchr(cursor, '\n');
    if (!newline) break;
    cursor = newline + 1;
  }
  return false;
}

/* The placeholder of the items that need the window server.

   An alias item draws a captured menu bar item (src/alias.c:206-223) and a
   space item draws a captured space (src/image.c:67-76). The preview has
   no window server, so the item keeps a box of a fixed size. A width of
   the config wins over the placeholder. */
static void preview_apply_placeholder(struct bar_item* item) {
  if (item->has_const_width) return;
  if (item->type != BAR_COMPONENT_ALIAS && item->type != BAR_COMPONENT_SPACE) return;

  item->custom_width = PREVIEW_PLACEHOLDER_SIZE;
  item->has_const_width = true;
}

static int preview_apply_item_property(sb_preview_t* preview,
                                       struct bar_item* item,
                                       const char* key,
                                       const char* value) {
  /* The reset empties the default item, whichever item the property is
     addressed to (src/bar_item.c:1378). */
  if (strcmp(key, COMMAND_DEFAULT_RESET) == 0) {
    preview_reset_default_item();
    preview_clear_messages(preview);
    return SB_OK;
  }

  char* message = preview_build_message(key, value);
  if (!message) return SB_ERR_OUT_OF_MEMORY;

  char* buffer = NULL;
  size_t length = 0;
  preview_clear_messages(preview);
  FILE* rsp = open_memstream(&buffer, &length);
  if (!rsp) {
    free(message);
    return SB_ERR_OUT_OF_MEMORY;
  }

  bar_item_parse_set_message(item, message, rsp);
  fclose(rsp);
  free(message);

  preview->messages = buffer;

  preview_apply_placeholder(item);

  return preview_messages_have_error(preview->messages)
         ? SB_ERR_PROPERTY_REJECTED
         : SB_OK;
}

sb_preview_t* sb_preview_create(void) {
  if (g_preview) return NULL;

  sb_preview_t* preview = calloc(1, sizeof(sb_preview_t));
  if (!preview) return NULL;

  if (!preview_bar_manager_init()) {
    free(preview);
    return NULL;
  }

  g_preview = preview;
  return preview;
}

void sb_preview_destroy(sb_preview_t* preview) {
  if (!preview) return;

  /* The global model belongs to the live handle. A handle that is not the
     live one was already released, so there is nothing to do: the model must
     not be destroyed a second time, because bar_manager_destroy frees the
     bars of the manager without resetting them (src/bar_manager.c:1063). */
  if (preview != g_preview) return;

  preview_bar_manager_destroy();
  g_preview = NULL;
  preview_clear_messages(preview);
  free(preview);
}

int sb_preview_set_bar(sb_preview_t* preview, const char* key, const char* value) {
  if (!preview || !key) return SB_ERR_INVALID_ARGUMENT;

  char* message = preview_build_message(key, value);
  if (!message) return SB_ERR_OUT_OF_MEMORY;

  char* buffer = NULL;
  size_t length = 0;
  preview_clear_messages(preview);
  FILE* rsp = open_memstream(&buffer, &length);
  if (!rsp) {
    free(message);
    return SB_ERR_OUT_OF_MEMORY;
  }

  preview_parse_bar_set_message(rsp, message);
  fclose(rsp);
  free(message);

  preview->messages = buffer;
  return preview_messages_have_error(preview->messages)
         ? SB_ERR_PROPERTY_REJECTED
         : SB_OK;
}

int sb_preview_set_default(sb_preview_t* preview, const char* key, const char* value) {
  if (!preview || !key) return SB_ERR_INVALID_ARGUMENT;

  return preview_apply_item_property(preview,
                                     &g_bar_manager.default_item,
                                     key,
                                     value              );
}

int sb_preview_add_item(sb_preview_t* preview, const char* alias, const char* type) {
  if (!preview || !alias || alias[0] == '\0') return SB_ERR_INVALID_ARGUMENT;
  if (preview_find_item(alias)) return SB_ERR_ITEM_EXISTS;

  preview_clear_messages(preview);

  /* bar_manager_create_item never returns NULL. */
  struct bar_item* item = bar_manager_create_item(&g_bar_manager);

  char* name = preview_copy(alias);
  if (!name) {
    bar_manager_remove_item(&g_bar_manager, item);
    return SB_ERR_OUT_OF_MEMORY;
  }
  bar_item_set_name(item, name);

  /* The type of the add command of the daemon (src/message.c:196). A type
     the daemon does not know leaves the item a plain item, and the daemon
     says so. */
  if (type && type[0] != '\0' && !bar_item_set_type(item, type)) {
    char message[256];
    snprintf(message, sizeof(message),
             "[?] Add %s: Invalid type '%s', assuming 'item'\n",
             alias,
             type       );
    preview->messages = preview_copy(message);
  }

  preview_apply_placeholder(item);
  return SB_OK;
}

int sb_preview_set_item(sb_preview_t* preview, const char* alias, const char* key, const char* value) {
  if (!preview || !alias || !key) return SB_ERR_INVALID_ARGUMENT;

  struct bar_item* item = preview_find_item(alias);
  if (!item) return SB_ERR_ITEM_NOT_FOUND;

  return preview_apply_item_property(preview, item, key, value);
}

int sb_preview_set_display(sb_preview_t* preview, double widthPoints, double heightPoints, double scale) {
  if (!preview) return SB_ERR_INVALID_ARGUMENT;
  if (widthPoints <= 0 || heightPoints <= 0) return SB_ERR_INVALID_ARGUMENT;

  /* The preview keeps the fixed backing scale of 2.0 of SketchyBar
     (src/surface.c:37), so the argument is ignored. */
  (void)scale;
  preview_display_configure(widthPoints, heightPoints, PREVIEW_DISPLAY_SCALE);

  /* The bar of the preview is rebuilt, so its frame follows the new display
     (src/bar.c:516-522). */
  bar_manager_reset(&g_bar_manager);
  return SB_OK;
}

int sb_preview_set_menu_bar(sb_preview_t* preview, double heightPoints) {
  if (!preview || heightPoints < 0) return SB_ERR_INVALID_ARGUMENT;
  preview_display_set_menu_bar(heightPoints, heightPoints > 0);
  return SB_OK;
}

const char* sb_preview_messages(sb_preview_t* preview) {
  if (!preview) return "";
  return preview->messages ? preview->messages : "";
}
