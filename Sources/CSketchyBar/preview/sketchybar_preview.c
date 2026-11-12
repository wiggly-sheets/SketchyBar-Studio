#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "sketchybar_preview.h"

#include "bar_item.h"
#include "bar_manager.h"
#include "alias.h"
#include "display.h"
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
  /* The vendored token helpers copy a token into a stack buffer, so a
     huge value from a config would overflow the stack of the render. The
     limit is far above a real property value. */
  if (key_length == 0 || key_length > 256 || value_length > 8192) return NULL;
  char* message = malloc(key_length + value_length + 3);  if (!message) return NULL;

  memcpy(message, key, key_length);
  message[key_length] = '\0';
  if (value_length) memcpy(message + key_length + 1, value, value_length);
  message[key_length + 1 + value_length] = '\0';
  message[key_length + 2 + value_length] = '\0';
  return message;
}

/* True when the key and the value fit the limits of the preview. */
static bool preview_arguments_fit(const char* key, const char* value) {
  size_t key_length = key ? strlen(key) : 0;
  size_t value_length = value ? strlen(value) : 0;
  return key_length > 0 && key_length <= 256 && value_length <= 8192;
}

/* The message of a value that the preview refuses because it is too long. */
static void preview_add_message(sb_preview_t* preview, const char* message);

static void preview_report_long_value(sb_preview_t* preview, const char* key) {
  char message[256];
  snprintf(message, sizeof(message),
           "[!] %s: the value is too long for the preview (limit 8192 bytes)\n",
           key ? key : "property");
  preview_add_message(preview, message);
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
    unsigned long parsed = argument ? strtoul(argument, NULL, 0) : 0;
    // A width the bitmap cannot hold would make the graph allocate a huge
    // buffer and the surface a huge window. The daemon has no such guard;
    // the preview refuses the item instead of crashing.
    if (parsed == 0 || parsed > 4096) {
      char message[256];
      snprintf(message, sizeof(message),
               "[!] Add %s: A graph needs a width between 1 and 4096\n",
               alias             );
      preview_clear_messages(preview);
      preview->messages = preview_copy(message);
      return false;
    }
    uint32_t width = (uint32_t)parsed;
    graph_setup(&item->graph, width);
  } else if (item->type == BAR_COMPONENT_SLIDER) {
    unsigned long parsed = argument ? strtoul(argument, NULL, 0) : 0;
    if (parsed == 0 || parsed > 4096) {
      char message[256];
      snprintf(message, sizeof(message),
               "[!] Add %s: A slider needs a width between 1 and 4096\n",
               alias             );
      preview_clear_messages(preview);
      preview->messages = preview_copy(message);
      return false;
    }
    slider_setup(&item->slider, (uint32_t)parsed);
  } else if (item->type == BAR_COMPONENT_RING) {
    long parsed = argument ? strtol(argument, NULL, 0) : 0;
    if (parsed <= 0 || parsed > 4096) {
      char message[256];
      snprintf(message, sizeof(message),
               "[!] Add %s: Ring diameter must be between 1 and 4096\n",
               alias             );
      preview_clear_messages(preview);
      preview->messages = preview_copy(message);
      return false;
    }
    ring_setup(&item->ring, (uint32_t)parsed);
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
        struct bar_item* member_item = g_bar_manager.bar_items[index];
        /* A nested bracket is not reparented into the outer group: its own
           group owns it, and moving it would make its destroy release the
           outer group. The preview says it cannot draw the nesting and
           keeps both groups intact. */
        if (member_item->type == BAR_COMPONENT_GROUP) {
          char message[256];
          snprintf(message, sizeof(message),
                   "[?] Add (Group) %s: nested bracket '%s' is not supported by the preview\n",
                   item->name ? item->name : alias,
                   member              );
          preview_add_message(preview, message);
          if (first) {
            free(list);
            return false;
          }
          if (last) break;
          member = end + 1;
          continue;
        }
        /* A member can be listed in two brackets. Leaving the old group
           first keeps its member list from pointing at an item that now
           belongs to another group after the old bracket is destroyed. */
        if (member_item->group && member_item->group != item->group) {
          group_remove_member(member_item->group, member_item);
        }
        group_add_member(item->group, member_item);
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

  if (!preview_arguments_fit(key, value)) {
    preview_clear_messages(preview);
    preview_report_long_value(preview, key);
    return SB_ERR_INVALID_ARGUMENT;
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
  if (!preview_arguments_fit(key, value)) {
    preview_clear_messages(preview);
    preview_report_long_value(preview, key);
    return SB_ERR_INVALID_ARGUMENT;
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
    preview_add_message(preview, message);
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
    preview_add_message(preview, message);
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
  if (!isfinite(widthPoints) || !isfinite(heightPoints)) return SB_ERR_INVALID_ARGUMENT;
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
  if (!preview || !isfinite(heightPoints) || heightPoints < 0) return SB_ERR_INVALID_ARGUMENT;
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

/* --- The scripts of the items --------------------------------------------- */

/* The answer of a run of the scripts, in the codes of the public API. */
static int preview_script_status_code(void) {
  switch (preview_script_status()) {
    case PREVIEW_SCRIPT_OUTCOME_TIMEOUT: return SB_ERR_SCRIPT_TIMEOUT;
    case PREVIEW_SCRIPT_OUTCOME_FAILED: return SB_ERR_SCRIPT_FAILED;
    default: return SB_OK;
  }
}

int sb_preview_set_script_environment(const char* shim_directory,
                                       const char* sink_path,
                                       const char* log_directory) {
  if (!shim_directory || !sink_path || !log_directory) return SB_ERR_INVALID_ARGUMENT;

  preview_set_script_environment(shim_directory, sink_path, log_directory);
  return SB_OK;
}

int sb_preview_run_item_scripts(sb_preview_t* preview) {
  if (!preview) return SB_ERR_INVALID_ARGUMENT;
  if (!preview_script_environment_ready()) {
    preview_add_message(preview, "The scripts of the items were not run, because the isolated environment of the preview is not installed.");
    return SB_ERR_INVALID_ARGUMENT;
  }

  /* Lay the bar out before the scripts run, so the gate of `when_shown`
     sees the bar of this tree and not the state of the previous one. */
  bar_manager_refresh(&g_bar_manager, true);

  for (uint32_t i = 0; i < g_bar_manager.bar_item_count; i++) {
    struct bar_item* item = g_bar_manager.bar_items[i];
    if (!item || !item->script || !item->script[0]) continue;
    if (!item->name) continue;

    /* The report of the script names the item it belongs to. */
    preview_set_current_script(item->name);

    /* The state of the item: the daemon keeps its items for as long as
       the config lives, so the counter of the item and the fact that it
       was on a bar survive there (src/bar_item.c:126-133). The preview
       rebuilds its item tree, so the counter comes from the registry of
       the shim and goes back into it. Whether the item is shown comes from
       the layout above, so the first render of a config runs the script
       the daemon would run. */
    item->counter = preview_item_counter_for(item->name);
    if (bar_item_is_shown(item)) {
      bar_item_append_associated_bar(item, display_active_display_adid());
    }

    /* The daemon runs the script of an item from its clock, with the
       routine of the item and nothing else (src/bar_manager.c:554):
       bar_item_update(bar_item, NULL, false, NULL).

       The gate of the daemon decides whether the script runs at all:
       `updates = false` never runs it, an item without `update_freq`
       runs it only on an event, and `updates = when_shown` runs it only
       while the item is on a bar (src/bar_item.c:127-139).

       The child gets the environment of the item itself: the name of the
       item, the variables of the item and the sender (src/bar_item.c:142-161).
       The preview does not have to build that environment. */
    bar_item_update(item, NULL, false, NULL);

    preview_item_counter_store(item->name, item->counter);
  }

  preview_wait_for_scripts(PREVIEW_SCRIPT_TIMEOUT * 1000);
  return preview_script_status_code();
}

int sb_preview_run_scripts(const char* const* aliases,
                            const char* const* scripts,
                            size_t count) {
  if (!aliases || !scripts) return SB_ERR_INVALID_ARGUMENT;
  if (!preview_script_environment_ready()) {
    return SB_ERR_INVALID_ARGUMENT;
  }

  char** alias_buffer = calloc(count ? count : 1, sizeof(char*));
  char** script_buffer = calloc(count ? count : 1, sizeof(char*));
  if (!alias_buffer || !script_buffer) {
    free(alias_buffer);
    free(script_buffer);
    return SB_ERR_OUT_OF_MEMORY;
  }

  for (size_t i = 0; i < count; i++) {
    alias_buffer[i] = (char*)aliases[i];
    script_buffer[i] = (char*)scripts[i];
  }

  bool started = preview_run_scripts(alias_buffer, script_buffer, count);

  free(alias_buffer);
  free(script_buffer);

  /* One wait for the whole batch: the batch has one deadline, so N
     scripts that hang cost one timeout and not N of them. */
  preview_wait_for_scripts(PREVIEW_SCRIPT_TIMEOUT * 1000);
  if (!started && preview_script_status() == PREVIEW_SCRIPT_OUTCOME_OK) {
    return SB_ERR_SCRIPT_FAILED;
  }
  return preview_script_status_code();
}

const char* sb_preview_item_script(sb_preview_t* preview, const char* alias) {
  if (!preview || !alias) return NULL;

  struct bar_item* item = preview_find_item(alias);
  if (!item || !item->script) return NULL;
  return item->script;
}

const char* sb_preview_script_messages(void) {
  return preview_script_messages();
}
