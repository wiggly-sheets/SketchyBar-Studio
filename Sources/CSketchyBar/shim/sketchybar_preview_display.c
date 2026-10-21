#include "display.h"
#include "misc/helpers.h"
#include "preview_shim.h"

/* The virtual display of the preview.
   The daemon asks the window server for the real displays; the preview has
   none, so every display call answers for the single virtual display. The
   frame of the display and its menu bar come from the configuration below,
   which sb_preview_set_display fills. */

static struct preview_display g_display = {
  PREVIEW_DISPLAY_WIDTH,
  PREVIEW_DISPLAY_HEIGHT,
  PREVIEW_DISPLAY_SCALE,
  false,
  PREVIEW_MENU_BAR_HEIGHT,
  false
};

void preview_display_configure(double width, double height, double scale) {
  g_display.width = width;
  g_display.height = height;

  /* The preview keeps the fixed backing scale of 2.0 of SketchyBar
     (src/surface.c:37): the scale of the screen is not a parameter of the
     layout, so the argument is ignored. */
  (void)scale;
  g_display.scale = PREVIEW_DISPLAY_SCALE;

  /* The menu bar is not touched: the caller sets it after the display, with
     sb_preview_set_menu_bar. */
}

void preview_display_reset(void) {
  g_display.width = PREVIEW_DISPLAY_WIDTH;
  g_display.height = PREVIEW_DISPLAY_HEIGHT;
  g_display.scale = PREVIEW_DISPLAY_SCALE;
  g_display.menu_bar_visible = false;
  g_display.menu_bar_height = PREVIEW_MENU_BAR_HEIGHT;
  g_display.has_notch = false;
}

void preview_display_set_menu_bar(double height, bool visible) {
  g_display.menu_bar_height = height;
  g_display.menu_bar_visible = visible;
}

void preview_display_set_notch(bool has_notch) {
  g_display.has_notch = has_notch;
}

bool preview_display_has_notch(void) {
  return g_display.has_notch;
}

const struct preview_display* preview_display_config(void) {
  return &g_display;
}

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
  return g_display.menu_bar_visible;
}

CGRect display_menu_bar_rect(uint32_t did) {
  if (!g_display.menu_bar_visible) return CGRectZero;
  return CGRectMake(0, 0, g_display.width, g_display.menu_bar_height);
}

uint32_t display_active_display_count(void) {
  return 1;
}

uint32_t* display_active_display_list(uint32_t* count) {
  uint32_t* list = malloc(sizeof(uint32_t));
  if (!list) {
    *count = 0;
    return NULL;
  }
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
  return CGRectMake(0, 0, g_display.width, g_display.height);
}

uint64_t display_space_id(uint32_t did) {
  return PREVIEW_SPACE_ID;
}

uint64_t* display_space_list(uint32_t did, int* count) {
  uint64_t* list = malloc(sizeof(uint64_t));
  if (!list) {
    *count = 0;
    return NULL;
  }
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
  return space_index == 1 ? PREVIEW_DISPLAY_ID : 0;
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
