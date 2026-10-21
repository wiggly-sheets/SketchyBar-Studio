#include "alias.h"
#include "misc/helpers.h"
#include "source_pid.h"
#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CoreFoundation.h>

struct menu_item {
  char* owner;
  char* name;

  float x_pos;
  uint32_t wid;
  uint64_t layer;

  CGRect bounds;
};

void menu_item_init(struct menu_item* menu_item) {
  memset(menu_item, 0, sizeof(struct menu_item)); 
  menu_item->x_pos = g_nirvana.x;
}

void menu_item_clear(struct menu_item* menu_item) {
  if (menu_item->name) free(menu_item->name);
  if (menu_item->owner) free(menu_item->owner);
  memset(menu_item, 0, sizeof(struct menu_item)); 
}

struct menu_item_list {
  struct menu_item* menu_items;
  uint32_t menu_item_count;
};

void menu_item_list_init(struct menu_item_list* menu_item_list, uint32_t menu_item_count) {
  menu_item_list->menu_items = malloc(sizeof(struct menu_item)*menu_item_count);
  menu_item_list->menu_item_count = menu_item_count;
  for (int i = 0; i < menu_item_count; i++) {
    menu_item_init(menu_item_list->menu_items + i);
  }
}

void menu_item_list_sort(struct menu_item_list* menu_item_list) {
  struct menu_item tmp;
  for (int i = 0; i < menu_item_list->menu_item_count; i++) {
    float highest_value = g_nirvana.x;
    uint32_t highest_value_index = 0;
    for (int j = i; j < menu_item_list->menu_item_count; j++) {
      if (menu_item_list->menu_items[j].x_pos > highest_value) {
        highest_value = menu_item_list->menu_items[j].x_pos;
        highest_value_index = j;
      }
    }
    if (i != highest_value_index) {
      tmp = menu_item_list->menu_items[i];
      menu_item_list->menu_items[i]
                            = menu_item_list->menu_items[highest_value_index];
      menu_item_list->menu_items[highest_value_index] = tmp;
    }
  }
}

void menu_item_list_clear(struct menu_item_list* menu_item_list) {
  if (menu_item_list->menu_items) {
    for (int i = 0; i < menu_item_list->menu_item_count; i++) {
      menu_item_clear(menu_item_list->menu_items + i);
    }
    free(menu_item_list->menu_items);
  }
  memset(menu_item_list, 0, sizeof(struct menu_item_list)); 
}

struct menu_item_list get_menu_item_list() {
  /* The preview has no window server. The enumeration of the menu bar items
     would need the Screen Recording permission, and the app must never ask
     for it because a config holds an alias item. The preview has no menu
     bar item to find. */
  struct menu_item_list menu_item_list;
  memset(&menu_item_list, 0, sizeof(menu_item_list));
  return menu_item_list;
}

void print_all_menu_items(FILE* rsp) {
  struct menu_item_list menu_item_list = get_menu_item_list();
  if (menu_item_list.menu_item_count > 0) {
    fprintf(rsp, "[\n");
    int counter = 0;
    for (int i = 0; i < menu_item_list.menu_item_count; i++) {
      struct menu_item* item = menu_item_list.menu_items + i;
      if (counter++ > 0) {
        fprintf(rsp, ", \n");
      }
      fprintf(rsp, "\t\"%s,%s(%d)\"", item->owner,
                                      item->name,
                                      counter     );
    }
    fprintf(rsp, "\n]\n");
  }
  menu_item_list_clear(&menu_item_list);
}

void alias_get_permission(struct alias* alias) {
  /* The preview never asks for the Screen Recording permission: the app
     must not show a permission prompt because a config holds an alias
     item. The permission stays false, so the alias item draws its
     placeholder. */
  alias->permission = false;
}

void alias_init(struct alias* alias) {
  alias->name = NULL;
  alias->owner = NULL;
  alias->color_override = false;
  color_init(&alias->color, 0xffff0000);
  alias->update_frequency = 1;
  alias->counter = 0;
  alias->pid = 0;

  window_init(&alias->window);
  image_init(&alias->image);
}

static void alias_find_window(struct alias* alias) {
  struct menu_item_list menu_item_list = get_menu_item_list();
  
  for (int i = 0; i < menu_item_list.menu_item_count; ++i) {
    struct menu_item* item = menu_item_list.menu_items + i;
    if (!alias->owner || strcmp(alias->owner, item->owner) != 0) continue;
    if (!alias->name || strcmp(alias->name, item->name) != 0) {
      if (alias->name) {
        char indexed_name[strlen(alias->name) + 32];
        snprintf(indexed_name, strlen(alias->name) + 32,
                               "%s(%d)",
                               item->name,
                               i + 1                    );
        if (strcmp(alias->name, indexed_name) != 0) continue; 
      } else if (strcmp(item->name, "") != 0) continue;
    }

    alias->window.id = item->wid;
    alias->window.frame.size = item->bounds.size;
    alias->window.origin = item->bounds.origin;

    pid_t source_pid = source_pid_for_window(item->bounds);
    if (source_pid > 0) {
      alias->pid = source_pid;
    }

    menu_item_list_clear(&menu_item_list);
    return;
  }
  alias->window.id = 0;
  menu_item_list_clear(&menu_item_list);
}

static bool alias_update_image(struct alias* alias, bool forced) {
  if (alias->window.id == 0) alias_find_window(alias);
  if (alias->window.id == 0) return false;

  bool disabled = false;
  CGImageRef image_ref = window_capture(&alias->window, &disabled);

  if (!image_ref) {
    if (!disabled) {
      alias->window.id = 0;
      image_destroy(&alias->image);
    }
    return false;
  }

  return image_set_image(&alias->image,
                         image_ref,
                         alias->window.frame,
                         forced              );
}

void alias_setup(struct alias* alias, char* owner, char* name) {
  alias->name = name;
  alias->owner = owner;
  alias_get_permission(alias);
  alias_update_image(alias, true);
}

uint32_t alias_get_length(struct alias* alias) {
  if (alias->image.image_ref) return alias->image.bounds.size.width;
  return 0;
}

uint32_t alias_get_height(struct alias* alias) {
  if (alias->image.image_ref) return alias->image.bounds.size.height;
  return 0;
}

bool alias_update(struct alias* alias, bool forced) {
  if (alias->update_frequency == 0) return false;

  alias->counter++;
  if (forced || alias->counter >= alias->update_frequency) {
    alias->counter = 0;
    if (alias_update_image(alias, forced)) {
      return true;
    }
  }
  return false;
}

void alias_draw(struct alias* alias, CGContextRef context) {
  if (alias->color_override) {
    CGContextSaveGState(context);
    image_draw(&alias->image, context);
    CGContextClipToMask(context, alias->image.bounds, alias->image.image_ref);
    CGContextSetRGBFillColor(context,
                             alias->color.r,
                             alias->color.g,
                             alias->color.b,
                             alias->color.a );

    CGContextFillRect(context, alias->image.bounds);
    CGContextRestoreGState(context);
  }
  else {
    image_draw(&alias->image, context);
  }
}

void alias_destroy(struct alias* alias) {
  image_destroy(&alias->image);
  if (alias->name) free(alias->name);
  if (alias->owner) free(alias->owner);
  alias->name = NULL;
  alias->owner = NULL;
}

void alias_calculate_bounds(struct alias* alias, uint32_t x, uint32_t y) {
  image_calculate_bounds(&alias->image, x, y);
}

bool alias_parse_sub_domain(struct alias* alias, FILE* rsp, struct token property, char* message) {
  struct key_value_pair key_value_pair = get_key_value_pair(property.text,'.');
  if (key_value_pair.key && key_value_pair.value) {
    struct token subdom = { key_value_pair.key, strlen(key_value_pair.key) };
    struct token entry = { key_value_pair.value, strlen(key_value_pair.value)};
    if (token_equals(subdom, SUB_DOMAIN_SHADOW))
      return shadow_parse_sub_domain(&alias->image.shadow,
                                     rsp,
                                     entry,
                                     message              );
    else if (token_equals(subdom, SUB_DOMAIN_COLOR)) {
      bool changed = !alias->color_override;
      alias->color_override = true;
      return color_parse_sub_domain(&alias->color, rsp, entry, message)
            || changed;
    }
    else {
      respond(rsp, "[!] Alias: Invalid subdomain '%s'\n", subdom.text);
    }
  }
  else if (token_equals(property, PROPERTY_COLOR)) {
    color_set_hex(&alias->color, token_to_uint32t(get_token(&message)));
    alias->color_override = true;
    return true;
  } else if (token_equals(property, PROPERTY_SCALE)) {
    return image_set_scale(&alias->image, token_to_float(get_token(&message)));
  } else if (token_equals(property, PROPERTY_UPDATE_FREQ)) {
    alias->update_frequency = token_to_uint32t(get_token(&message));
    return false;
  } else {
    respond(rsp, "[!] Alias: Invalid property '%s' \n", property.text);
  }
  return false;
}
