#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sketchybar_preview.h"

#include "bar_item.h"
#include "bar_manager.h"
#include "preview_internal.h"
#include "surface.h"
#include "window.h"

/* The test-only accessors of the preview core. They read the state of the
   vendored model, so the tests of the preview can assert on it without
   reaching into the vendored tree. The app never calls them. */

int sb_preview_test_item_width(sb_preview_t* preview, const char* alias) {
  if (!preview) return -1;
  struct bar_item* item = preview_find_item(alias);
  if (!item) return -1;
  if (!item->has_const_width) return -1;
  return (int) item->custom_width;
}

int sb_preview_test_item_padding_left(sb_preview_t* preview, const char* alias) {
  if (!preview) return -1;
  struct bar_item* item = preview_find_item(alias);
  if (!item) return -1;
  return (int) item->background.padding_left;
}

char* sb_preview_test_item_serialize(sb_preview_t* preview, const char* alias) {
  if (!preview) return NULL;
  struct bar_item* item = preview_find_item(alias);
  if (!item) return NULL;

  /* The same text the daemon answers with for `sketchybar --query <item>`
     (src/bar_item.c:965).

     The text is NOT always valid JSON: bar_item_serialize writes the text
     of a label without escaping it (src/text.c:1027), so a label that
     holds a quote or a newline breaks a JSON parser. The daemon has the
     same defect, so the text is read as text and not as JSON. */
  char* buffer = NULL;
  size_t length = 0;
  FILE* rsp = open_memstream(&buffer, &length);
  if (!rsp) return NULL;

  bar_item_serialize(item, rsp);
  fclose(rsp);
  return buffer;
}

CGImageRef sb_preview_test_item_image(sb_preview_t* preview, const char* alias) {
  if (!preview || !alias) return NULL;
  struct bar_item* item = preview_find_item(alias);
  if (!item) return NULL;
  if (item->num_windows < 1 || !item->windows[0]) return NULL;

  /* The bitmap of the item itself, so a test can see what an export of
     the item alone would show. */
  struct window* window = item->windows[0];
  if (!window->surface || !window->surface->context) return NULL;

  return CGBitmapContextCreateImage(window->surface->context);
}

char* sb_preview_test_child_environment(void) {
  char** environment = preview_build_environment(NULL);
  if (!environment) return NULL;

  size_t length = 1;
  for (char** entry = environment; *entry; entry++) {
    length += strlen(*entry) + 1;
  }

  char* text = malloc(length);
  if (!text) {
    preview_free_environment(environment);
    return NULL;
  }

  text[0] = '\0';
  for (char** entry = environment; *entry; entry++) {
    if (text[0] != '\0') strcat(text, "\n");
    strcat(text, *entry);
  }

  preview_free_environment(environment);
  return text;
}
