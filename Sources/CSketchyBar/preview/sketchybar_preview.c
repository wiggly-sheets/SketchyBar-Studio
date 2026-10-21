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

static bool g_preview_alive = false;

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
  return preview_messages_have_error(preview->messages)
         ? SB_ERR_PROPERTY_REJECTED
         : SB_OK;
}

sb_preview_t* sb_preview_create(void) {
  if (g_preview_alive) return NULL;

  sb_preview_t* preview = calloc(1, sizeof(sb_preview_t));
  if (!preview) return NULL;

  if (!preview_bar_manager_init()) {
    free(preview);
    return NULL;
  }

  g_preview_alive = true;
  return preview;
}

void sb_preview_destroy(sb_preview_t* preview) {
  if (!preview) return;
  preview_bar_manager_destroy();
  preview_clear_messages(preview);
  free(preview);
  g_preview_alive = false;
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

int sb_preview_add_item(sb_preview_t* preview, const char* alias) {
  if (!preview || !alias || alias[0] == '\0') return SB_ERR_INVALID_ARGUMENT;
  if (preview_find_item(alias)) return SB_ERR_ITEM_EXISTS;

  struct bar_item* item = bar_manager_create_item(&g_bar_manager);
  if (!item) return SB_ERR_OUT_OF_MEMORY;

  char* name = preview_copy(alias);
  if (!name) {
    bar_manager_remove_item(&g_bar_manager, item);
    return SB_ERR_OUT_OF_MEMORY;
  }
  bar_item_set_name(item, name);
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

  preview_display_configure(widthPoints, heightPoints, scale);

  /* The bar of the preview is rebuilt, so its frame follows the new display
     (src/bar.c:516-522). */
  bar_manager_reset(&g_bar_manager);
  return SB_OK;
}

const char* sb_preview_messages(sb_preview_t* preview) {
  if (!preview) return "";
  return preview->messages ? preview->messages : "";
}
