#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "preview_internal.h"

#include "bar.h"
#include "bar_manager.h"
#include "display.h"
#include "misc/helpers.h"

/* The bar of the preview.

   The daemon routes the properties of the bar through the bar domain of
   src/message.c (src/message.c:338-464). That file is not vendored, because
   it depends on the Mach machinery, so the bar domain lives here. The
   dispatch is the dispatch of the daemon, property for property, so the bar
   of the preview holds the same values as the bar of the daemon.

   The lifecycle of the global bar manager lives here too. The daemon calls
   bar_manager_init (src/bar_manager.c:21-79), which starts a CVDisplayLink
   and a 1 Hz timer on the main run loop of the app. The preview never calls
   it: the fields below are the fields of bar_manager_init, and the timer of
   the daemon is left out. */

bool preview_bar_manager_init(void) {
  struct bar_manager* bar_manager = &g_bar_manager;

  bar_manager->font_smoothing = false;
  bar_manager->any_bar_hidden = false;
  bar_manager->needs_ordering = false;
  bar_manager->bar_needs_update = false;
  bar_manager->bars = NULL;
  bar_manager->bar_count = 0;
  bar_manager->bar_items = NULL;
  bar_manager->bar_item_count = 0;
  bar_manager->displays = DISPLAY_ALL_PATTERN;
  bar_manager->position = POSITION_TOP;
  bar_manager->shadow = false;
  bar_manager->blur_radius = 0;
  bar_manager->margin = 0;
  bar_manager->frozen = false;
  bar_manager->sleeps = false;
  bar_manager->window_level = kCGBackstopMenuLevel;
  bar_manager->topmost = false;
  bar_manager->notch_width = 200;
  bar_manager->notch_offset = 0;
  bar_manager->notch_display_height = 0;
  bar_manager->active_adid = display_active_display_adid();
  bar_manager->might_need_clipping = false;

  bar_manager->sticky = true;

  bar_manager->show_in_fullscreen = false;

  /* The clock of the daemon is a 1 Hz timer on the main run loop
     (src/bar_manager.c:67-78). The preview has no clock. */
  bar_manager->clock = NULL;

  image_init(&bar_manager->current_artwork);
  background_init(&bar_manager->background);
  bar_manager->background.bounds.size.height = 25;
  bar_manager->background.overrides_height = true;
  bar_manager->background.padding_left = 20;
  bar_manager->background.padding_right = 20;

  color_set_hex(&bar_manager->background.border_color, 0xffff0000);
  color_set_hex(&bar_manager->background.color, 0x44000000);

  bar_item_init(&bar_manager->default_item, NULL);
  bar_item_set_name(&bar_manager->default_item, string_copy("defaults"));
  custom_events_init(&bar_manager->custom_events);

  /* The animator of the daemon is created with animator_init, which starts
     a display link (src/animation.c:125-133). The patched
     animator_renew_display_link never creates one, and the duration of the
     animator stays 0, so no animation is ever created and the display link
     is never needed. */
  animator_init(&bar_manager->animator);

  return true;
}

void preview_bar_manager_destroy(void) {
  bar_manager_destroy(&g_bar_manager);
}

void preview_reset_default_item(void) {
  /* The daemon resets the default item with bar_item_init, which leaves the
     memory of the old item behind (src/bar_item.c:1363-1364). The preview
     destroys the item first, so a reset does not leak. The name stays NULL,
     like upstream. */
  bar_item_destroy(&g_bar_manager.default_item, false);
  memset(&g_bar_manager.default_item, 0, sizeof(struct bar_item));
  bar_item_init(&g_bar_manager.default_item, NULL);
}

struct bar_item* preview_find_item(const char* alias) {
  if (!alias) return NULL;
  for (uint32_t i = 0; i < g_bar_manager.bar_item_count; i++) {
    struct bar_item* item = g_bar_manager.bar_items[i];
    if (item->name && strcmp(item->name, alias) == 0) return item;
  }
  return NULL;
}

bool preview_parse_bar_set_message(FILE* rsp, char* message) {
  struct token command = get_token(&message);
  bool needs_refresh = false;

  if (token_equals(command, PROPERTY_MARGIN)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_margin,
            &g_bar_manager,
            g_bar_manager.margin,
            token_to_int(token)    );

  } else if (token_equals(command, PROPERTY_YOFFSET)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_y_offset,
            &g_bar_manager,
            g_bar_manager.background.y_offset,
            token_to_int(token)      );

  } else if (token_equals(command, PROPERTY_BLUR_RADIUS)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_background_blur,
            &g_bar_manager,
            g_bar_manager.blur_radius,
            token_to_int(token)             );

  } else if (token_equals(command, PROPERTY_FONT_SMOOTHING)) {
    struct token state = get_token(&message);
    needs_refresh = bar_manager_set_font_smoothing(&g_bar_manager,
                                                   evaluate_boolean_state(state,
                                                                          g_bar_manager.font_smoothing));
  } else if (token_equals(command, PROPERTY_SHADOW)) {
    struct token state = get_token(&message);
    needs_refresh = bar_manager_set_shadow(&g_bar_manager,
                                           evaluate_boolean_state(state,
                                                                  g_bar_manager.shadow));
  } else if (token_equals(command, PROPERTY_NOTCH_WIDTH)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_notch_width,
            &g_bar_manager,
            g_bar_manager.notch_width,
            token_to_int(token)         );

  } else if (token_equals(command, PROPERTY_NOTCH_OFFSET)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_notch_offset,
            &g_bar_manager,
            g_bar_manager.notch_offset,
            token_to_int(token)         );

  } else if (token_equals(command, PROPERTY_NOTCH_DISPLAY_HEIGHT)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_notch_display_height,
            &g_bar_manager,
            g_bar_manager.notch_display_height,
            token_to_int(token)         );

  } else if (token_equals(command, PROPERTY_HIDDEN)) {
    struct token state = get_token(&message);
    uint32_t adid = 0;
    if (token_equals(state, "current")) {
      adid = display_active_display_adid();

      if (adid > 0 && adid <= g_bar_manager.bar_count)
        needs_refresh = bar_manager_set_hidden(&g_bar_manager,
                                               adid,
                                               !g_bar_manager.bars[adid - 1]->hidden);
      else
        respond(rsp, "[!] Bar: No bar on display %u\n", adid);
    } else needs_refresh = bar_manager_set_hidden(&g_bar_manager,
                                                  adid,
                                                  evaluate_boolean_state(state,
                                                                         g_bar_manager.any_bar_hidden));
  } else if (token_equals(command, PROPERTY_TOPMOST)) {
    struct token token = get_token(&message);
    if (token_equals(token, ARGUMENT_WINDOW)) {
      needs_refresh = bar_manager_set_topmost(&g_bar_manager,
                                              TOPMOST_LEVEL_WINDOW,
                                              true                 );
    } else {
      needs_refresh = bar_manager_set_topmost(&g_bar_manager,
                                              TOPMOST_LEVEL_ALL,
                                              evaluate_boolean_state(token,
                                                                     g_bar_manager.topmost));
    }
  } else if (token_equals(command, PROPERTY_STICKY)) {
    struct token token = get_token(&message);
    needs_refresh = bar_manager_set_sticky(&g_bar_manager,
                                           evaluate_boolean_state(token,
                                                                  g_bar_manager.sticky));
  } else if (token_equals(command, PROPERTY_DISPLAY)) {
    struct token display = get_token(&message);

    uint32_t display_pattern = 0;
    uint32_t count;
    char** list = token_split(display, ',', &count);
    if (list && count > 0) {
      for (int i = 0; i < count; i++) {
        if (strcmp(list[i], ARGUMENT_DISPLAY_ALL) == 0) {
          display_pattern = DISPLAY_ALL_PATTERN;
        } else if (strcmp(list[i], ARGUMENT_DISPLAY_MAIN) == 0) {
          display_pattern = DISPLAY_MAIN_PATTERN;
        }
        else {
          display_pattern |= 1 << (strtoul(list[i], NULL, 0) - 1);
        }
      }
      free(list);
    }
    needs_refresh = bar_manager_set_displays(&g_bar_manager, display_pattern);
  } else if (token_equals(command, PROPERTY_POSITION)) {
    struct token position = get_token(&message);
    if (position.length > 0)
      needs_refresh = bar_manager_set_position(&g_bar_manager, position.text[0]);
  } else if (token_equals(command, PROPERTY_CLIP)) {
    respond(rsp, "[!] Bar: Invalid property 'clip'\n");
  } else if (token_equals(command, PROPERTY_HEIGHT)) {
    struct token token = get_token(&message);
    ANIMATE(bar_manager_set_bar_height,
            &g_bar_manager,
            g_bar_manager.background.bounds.size.height,
            token_to_int(token)                         );
  } else if (token_equals(command, PROPERTY_SHOW_IN_FULLSCREEN)) {
      struct token token = get_token(&message);

      needs_refresh = bar_manager_set_show_in_fullscreen(&g_bar_manager,
          evaluate_boolean_state(token, g_bar_manager.show_in_fullscreen));
  } else
    needs_refresh = background_parse_sub_domain(&g_bar_manager.background, rsp, command, message);

  return needs_refresh;
}
