#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sketchybar_preview.h"

#include "bar_item.h"
#include "bar_manager.h"
#include "alias.h"
#include "graph.h"
#include "group.h"
#include "misc/helpers.h"
#include "preview_internal.h"
#include "ring.h"
#include "slider.h"

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

/* Adds a message to the messages of the preview.

   The daemon answers with one stream, so a message joins the ones that are
   already there (src/message.c:468-478). */
static void preview_add_message(sb_preview_t* preview, const char* message) {
  size_t length = strlen(message);
  size_t old_length = preview->messages ? strlen(preview->messages) : 0;
  char* buffer = realloc(preview->messages, old_length + length + 1);
  if (!buffer) return;
  memcpy(buffer + old_length, message, length + 1);
  preview->messages = buffer;
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

/* The setup of the types that need one, exactly as the daemon does it when
   it reads an add command (src/message.c:218-256): the width of a graph
   and of a slider, the diameter of a ring, the owner and the name of an
   alias, and the members of a bracket.

   The argument is the trailing argument of the add command. The daemon
   removes a ring whose diameter is not positive (src/message.c:236-248),
   and so does the preview. */
static bool preview_apply_add_argument(sb_preview_t* preview,
                                       struct bar_item* item,
                                       const char* argument,
                                       const char* alias) {
  if (item->type == BAR_COMPONENT_GRAPH) {
    uint32_t width = argument ? (uint32_t)strtoul(argument, NULL, 0) : 0;
    if (width == 0) {
      /* The daemon draws a graph of no width and divides by the width of
         the graph (src/graph.c:24), so it crashes. The preview refuses the
         item instead, so the process of the app survives. */
      char message[256];
      snprintf(message, sizeof(message),
               "[!] Add %s: A graph needs a width\n",
               alias             );
      preview_clear_messages(preview);
      preview->messages = preview_copy(message);
      return false;
    }
    graph_setup(&item->graph, width);
  } else if (item->type == BAR_COMPONENT_SLIDER) {
    slider_setup(&item->slider, argument ? (uint32_t)strtoul(argument, NULL, 0) : 0);
  } else if (item->type == BAR_COMPONENT_RING) {
    int diameter = argument ? (int)strtol(argument, NULL, 0) : 0;
    if (diameter <= 0) {
      char message[256];
      snprintf(message, sizeof(message),
               "[!] Add %s: Ring diameter must be positive\n",
               alias             );
      preview_clear_messages(preview);
      preview->messages = preview_copy(message);
      return false;
    }
    ring_setup(&item->ring, (uint32_t)diameter);
  } else if (item->type == BAR_COMPONENT_ALIAS) {
    /* The daemon takes the owner and the name of an alias out of the name
       of the item, split at a comma, and it copies the two halves
       (src/message.c:238-249).

       The preview has to copy them too. get_key_value_pair returns
       pointers into the buffer it splits (src/misc/helpers.h:126-147), and
       alias_destroy frees the owner and the name of an alias one by one
       (src/alias.c:302-308), so the two halves of one buffer would be
       freed as if they were two buffers and the preview would abort. */
    char* split = preview_copy(alias);
    if (!split) return false;

    struct key_value_pair pair = get_key_value_pair(split, ',');
    if (!pair.key || !pair.value) {
      /* No comma (or a comma at the end): the whole name is the owner and
         the name of the alias is empty, like the daemon does. */
      free(split);
      char* owner = preview_copy(alias);
      if (!owner) return false;
      alias_setup(&item->alias, owner, NULL);
    } else {
      char* owner = preview_copy(pair.key);
      char* name = preview_copy(pair.value);
      free(split);
      if (!owner || !name) {
        free(owner);
        free(name);
        return false;
      }
      alias_setup(&item->alias, owner, name);
    }
  } else if (item->type == BAR_COMPONENT_GROUP) {
    /* The daemon reads the members of a bracket from the position token
       (src/message.c:263), because a bracket has no position token of its
       own. The bridge puts the member list in the argument of the add
       command, so the preview reads the members from there.

       The daemon adds the members to the group when it reads the add
       command (src/message.c:262-306), and it removes the bracket when
       the first member is not there (src/message.c:300-303). */
    char* list = preview_copy(argument ? argument : "");
    if (!list) return false;

    bool first = true;
    char* member = list;
    while (*member) {
      while (*member == ' ') member++;
      if (!*member) break;

      char* end = member;
      while (*end && *end != ' ') end++;
      bool last = (*end == '\0');
      *end = '\0';

      int index = bar_manager_get_item_index_for_name(&g_bar_manager, member);
      if (index >= 0) {
        group_add_member(item->group, g_bar_manager.bar_items[index]);
        first = false;
      } else {
        char message[256];
        snprintf(message, sizeof(message),
                 "[?] Add (Group) %s: Failed to add member '%s', item not found\n",
                 item->name ? item->name : alias,
                 member              );
        preview_add_message(preview, message);
        if (first) {
          /* The daemon removes the bracket when the first member is not
             there (src/message.c:300-303). */
          free(list);
          return false;
        }
      }

      if (last) break;
      member = end + 1;
    }

    free(list);
  }

  return true;
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

  /* The virtual display is a global of the shim, so the display of the
     preview before this one would leak into this one. The caller sets the
     display of its preview after it created it. */
  preview_display_reset();

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

int sb_preview_add_item(sb_preview_t* preview, const char* alias, const char* type,
                         const char* position, const char* argument) {
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

  /* The position of the add command. The daemon creates the item and
     removes it again when the position is missing or illegal
     (src/message.c:202-208), and so does the preview. */
  if (item->type != BAR_COMPONENT_GROUP
      && !bar_item_set_position(item, position ? position : "")) {
    char message[256];
    snprintf(message, sizeof(message),
             "[!] Add %s: Illegal position '%s'\n",
             alias,
             position ? position : "");
    preview->messages = preview_copy(message);
    bar_manager_remove_item(&g_bar_manager, item);
    return SB_ERR_PROPERTY_REJECTED;
  }

  /* The trailing argument of the add command (src/message.c:218-256). */
  if (!preview_apply_add_argument(preview, item, argument, alias)) {
    bar_manager_remove_item(&g_bar_manager, item);
    return SB_ERR_PROPERTY_REJECTED;
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

int sb_preview_set_notch(sb_preview_t* preview, int hasNotch) {
  if (!preview) return SB_ERR_INVALID_ARGUMENT;
  preview_display_set_notch(hasNotch != 0);
  return SB_OK;
}

const char* sb_preview_messages(sb_preview_t* preview) {
  if (!preview) return "";
  return preview->messages ? preview->messages : "";
}
