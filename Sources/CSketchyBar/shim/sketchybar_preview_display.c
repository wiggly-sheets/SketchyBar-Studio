#include "display.h"
#include "misc/helpers.h"
#include "preview_shim.h"

/* The virtual display of the preview.
   The daemon asks the window server for the real displays; the preview has
   none, so every display call answers for the single virtual display. */

uint32_t display_main_display_id(void) {
  return PREVIEW_DISPLAY_ID;
}

uint32_t display_active_display_id(void) {
  return PREVIEW_DISPLAY_ID;
}

uint32_t display_active_display_adid(void) {
  return 1;
}

uint32_t display_arrangement_display_id(int arrangement) {
  return PREVIEW_DISPLAY_ID;
}

bool display_menu_bar_visible(void) {
  return false;
}

CGRect display_menu_bar_rect(uint32_t did) {
  return CGRectZero;
}

uint32_t display_active_display_count(void) {
  return 1;
}

uint32_t* display_active_display_list(uint32_t* count) {
  uint32_t* list = malloc(sizeof(uint32_t));
  list[0] = PREVIEW_DISPLAY_ID;
  *count = 1;
  return list;
}

bool display_begin(void) {
  return true;
}

bool display_end(void) {
  return true;
}

CFStringRef display_uuid(uint32_t did) {
  return NULL;
}

CGRect display_bounds(uint32_t did) {
  return CGRectMake(0, 0, PREVIEW_DISPLAY_WIDTH, PREVIEW_DISPLAY_HEIGHT);
}

uint64_t display_space_id(uint32_t did) {
  return PREVIEW_SPACE_ID;
}

uint64_t* display_space_list(uint32_t did, int* count) {
  uint64_t* list = malloc(sizeof(uint64_t));
  list[0] = PREVIEW_SPACE_ID;
  *count = 1;
  return list;
}

int display_arrangement(uint32_t did) {
  return 1;
}

void forced_brightness_event(void) {
}

void begin_receiving_brightness_events(void) {
}

void display_serialize(FILE* rsp) {
  fprintf(rsp, "[]\n");
}

/* The Space helpers of src/misc/helpers.h. The daemon reads them from
   SkyLight; the preview has one space of its own. */

int preview_space_index(uint64_t space_id) {
  return space_id == PREVIEW_SPACE_ID ? 1 : 0;
}

uint64_t preview_space_display_id(uint32_t space_index) {
  return space_index == 1 ? PREVIEW_SPACE_ID : 0;
}

uint32_t preview_display_id_for_space(uint32_t space_index) {
  return space_index == 1 ? PREVIEW_DISPLAY_ID : 0;
}

int preview_space_type(uint64_t space_id) {
  return 0;
}

CGImageRef preview_space_capture(uint32_t space_index) {
  return NULL;
}
