#include "media.h"
#include "mouse.h"
#include "source_pid.h"
#include "workspace.h"

/* The symbols that the kept headers declare and the dropped files define.

   The headers of the dropped modules stay in the vendored tree, because the
   kept code includes them (src/source_pid.h, src/workspace.h, src/media.h,
   src/mouse.h). The implementations of the dropped files are gone, so the
   link would fail the moment a later stage calls one of them.

   None of them is called by the vendored tree today: the preview has no
   window server, no accessibility API, no media keys and no mouse. They are
   defined here as the safe no-ops they have to be, so that the link cannot
   break later.

   source_pid.h: the module finds the process behind a menu bar item with
   the accessibility API. The preview has no menu bar item.
   workspace.h: the module observes the spaces of the machine. The preview
   has one space of its own.
   media.h: the module reads the media keys. The preview has no media.
   mouse.h: the module reads the mouse. The preview has no input. */

bool source_pid_needs_workaround(void) {
  return false;
}

char* source_name_for_window(CGRect window_bounds) {
  return NULL;
}

void source_pid_cache_init(void) {
}

void source_pid_cache_refresh(void) {
}

void workspace_event_handler_init(void** context) {
}

void workspace_event_handler_begin(void** context) {
}

void workspace_event_handler_end(void* context) {
}

int workspace_display_notch_height(uint32_t did) {
  return 0;
}

char* workspace_copy_app_name_for_pid(pid_t pid) {
  return NULL;
}

void initialize_media_events() {
}

void mouse_begin(void) {
}
