#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sketchybar_preview.h"

#include "bar_item.h"
#include "bar_manager.h"
#include "preview_internal.h"

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

char* sb_preview_test_child_environment(void) {
  char** environment = preview_build_environment(NULL);
  if (!environment) return NULL;

  size_t length = 1;
  for (char** entry = environment; *entry; entry++) {
    length += strlen(*entry) + 1;
  }

  char* text = malloc(length);
  if (!text) return NULL;

  text[0] = '\0';
  for (char** entry = environment; *entry; entry++) {
    if (text[0] != '\0') strcat(text, "\n");
    strcat(text, *entry);
  }

  return text;
}
