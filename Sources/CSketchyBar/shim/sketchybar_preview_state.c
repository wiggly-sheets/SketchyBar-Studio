#include <stdlib.h>
#include <string.h>

#include "preview_shim.h"

/* The state of the items between two runs of the scripts.

   The daemon keeps its items for as long as the config lives, so the
   counter of an item and the fact that it was on a bar survive there
   (src/bar_item.c:126-133). The preview rebuilds its item tree on every
   render and on every tick of the timer, so the state of an item has to
   be kept here and given back to the item when the tree is built again.

   The key is the alias of the item, which is the name of the item: the
   daemon identifies its items by their name too (src/bar_item.c:401-403). */

struct preview_item_state {
  char* alias;
  uint32_t counter;
  bool shown;
};

static struct preview_item_state* g_preview_item_states = NULL;
static size_t g_preview_item_state_count = 0;
static size_t g_preview_item_state_capacity = 0;

/* The state of one item, or NULL when the item is unknown. */
static struct preview_item_state* preview_item_state_find(const char* alias) {
  if (!alias) return NULL;
  for (size_t i = 0; i < g_preview_item_state_count; i++) {
    if (strcmp(g_preview_item_states[i].alias, alias) == 0) return &g_preview_item_states[i];
  }
  return NULL;
}

/* The state of one item, created when the item is unknown. */
static struct preview_item_state* preview_item_state_ensure(const char* alias) {
  struct preview_item_state* state = preview_item_state_find(alias);
  if (state) return state;
  if (!alias || !*alias) return NULL;

  if (g_preview_item_state_count == g_preview_item_state_capacity) {
    size_t capacity = g_preview_item_state_capacity ? g_preview_item_state_capacity * 2 : 16;
    struct preview_item_state* grown = realloc(g_preview_item_states,
                                               sizeof(struct preview_item_state) * capacity);
    if (!grown) return NULL;
    g_preview_item_states = grown;
    g_preview_item_state_capacity = capacity;
  }

  size_t length = strlen(alias);
  char* copy = malloc(length + 1);
  if (!copy) return NULL;
  memcpy(copy, alias, length + 1);

  struct preview_item_state* created = &g_preview_item_states[g_preview_item_state_count++];
  created->alias = copy;
  created->counter = 0;
  created->shown = false;
  return created;
}

uint32_t preview_item_counter_for(const char* alias) {
  struct preview_item_state* state = preview_item_state_find(alias);
  return state ? state->counter : 0;
}

bool preview_item_shown_for(const char* alias) {
  struct preview_item_state* state = preview_item_state_find(alias);
  return state ? state->shown : false;
}

void preview_item_counter_store(const char* alias, uint32_t counter) {
  struct preview_item_state* state = preview_item_state_ensure(alias);
  if (!state) return;
  state->counter = counter;
}

void preview_item_shown_store(const char* alias, bool shown) {
  struct preview_item_state* state = preview_item_state_ensure(alias);
  if (!state) return;
  state->shown = shown;
}
