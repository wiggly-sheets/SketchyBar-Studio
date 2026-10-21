#include "event.h"
#include "bar_manager.h"
#include "custom_events.h"
#include "app_windows.h"
#include "media.h"
#include "power.h"
#include "volume.h"
#include "wifi.h"
#include "workspace.h"
#include "source_pid.h"

/* The event source and the globals of the daemon. The preview has no
   window server, no input and no notifications, so every event source is a
   no-op and every forced event does nothing. */

struct bar_manager g_bar_manager;
void* g_workspace_context = NULL;

void event_post(struct event* event) {
}

void forced_front_app_event(void) {
}

void forced_media_change_event(void) {
}

void forced_network_event(void) {
}

void forced_power_event(void) {
}

void forced_space_windows_event(void) {
}

void forced_volume_event(void) {
}

void begin_receiving_media_events(void) {
}

void begin_receiving_power_events(void) {
}

void begin_receiving_space_window_events(void) {
}

void begin_receiving_volume_events(void) {
}

void begin_receiving_network_events(void) {
}

void workspace_create_custom_observer(void** context, char* notification) {
}

float workspace_get_scale(void) {
  return 1.0f;
}

CGImageRef workspace_icon_for_app(char* app) {
  return NULL;
}

pid_t source_pid_for_window(CGRect window_bounds) {
  return 0;
}
