#!/usr/bin/env python3
"""Materialize the Stage 1 vendored SketchyBar subset.

Copies the upstream subset into Sources/CSketchyBar/src and applies the
patched changes of this file. Every patch is recorded in
Sources/CSketchyBar/MODIFICATIONS.md.

Usage: script/vendor_stage1.py [upstream-checkout]
"""

import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
UPSTREAM = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1 else "/Users/Zeb/Developer/SketchyBar"
)
SRC = ROOT / "Sources" / "CSketchyBar" / "src"

# The code of the preview itself. It is not upstream code, so it is not
# copied and never overwritten: only SRC is emptied and refilled below.
# A new file of the preview belongs in this directory, never in SRC, because
# SRC is emptied on every run of this script.
PREVIEW = ROOT / "Sources" / "CSketchyBar" / "preview"

# The upstream commit that was vendored. The script refuses to run against a
# different checkout, so the tree cannot be rebuilt from other code.
UPSTREAM_COMMIT = "f23f4f45302129aee7a2f6de6d6ae2cc9d7d7ed4"

# The upstream files that are compiled into the preview core.
COMPILED = [
    "alias.c",
    "alias.h",
    "animation.c",
    "animation.h",
    "background.c",
    "background.h",
    "bar.c",
    "bar.h",
    "bar_item.c",
    "bar_item.h",
    "bar_manager.c",
    "bar_manager.h",
    "color.c",
    "color.h",
    "context.c",
    "context.h",
    "custom_events.c",
    "custom_events.h",
    "font.c",
    "font.h",
    "graph.c",
    "graph.h",
    "group.c",
    "group.h",
    "image.c",
    "image.h",
    "popup.c",
    "popup.h",
    "ring.c",
    "ring.h",
    "shadow.c",
    "shadow.h",
    "slider.c",
    "slider.h",
    "symbol.h",
    "symbol.m",
    "text.c",
    "text.h",
    "misc/defines.h",
    "misc/env_vars.h",
    "misc/helpers.h",
]

# The upstream headers of the dropped modules. The kept code includes them,
# so the declarations stay, but their implementations are gone.
HEADERS = [
    "app_windows.h",
    "display.h",
    "event.h",
    "media.h",
    "mouse.h",
    "power.h",
    "source_pid.h",
    "surface.h",
    "volume.h",
    "wifi.h",
    "window.h",
    "workspace.h",
]


def check_upstream_commit():
    head = subprocess.run(
        ["git", "-C", str(UPSTREAM), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
    )
    if head.returncode != 0:
        sys.exit(
            f"cannot read the upstream commit of {UPSTREAM}: {head.stderr.strip()}"
        )

    actual = head.stdout.strip()
    if actual != UPSTREAM_COMMIT:
        sys.exit(
            f"the upstream checkout {UPSTREAM} is at {actual}, but "
            f"{UPSTREAM_COMMIT} was vendored; refusing to vendor other code"
        )


def copy_subset():
    if not (UPSTREAM / "src").is_dir():
        sys.exit(f"upstream checkout not found: {UPSTREAM}")

    check_upstream_commit()

    # The code of the preview lives outside SRC, so the emptying of SRC
    # below never touches it. The check keeps it that way, and it runs even
    # when the preview directory does not exist yet.
    preview_path = PREVIEW.resolve()
    src_path = SRC.resolve()
    if preview_path == src_path or src_path in preview_path.parents:
        sys.exit(f"the preview code must not live in {SRC}")

    if SRC.exists():
        shutil.rmtree(SRC)

    for name in COMPILED + HEADERS:
        source = UPSTREAM / "src" / name
        if not source.is_file():
            sys.exit(f"upstream file missing: {source}")
        target = SRC / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    license_target = ROOT / "Sources" / "CSketchyBar" / "LICENSE.md"
    shutil.copyfile(UPSTREAM / "LICENSE.md", license_target)


copy_subset()


def patch(path, old, new, count=1):
    file = SRC / path
    text = file.read_text()
    if text.count(old) != count:
        sys.exit(f"patch target not found exactly {count}x in {path}:\n{old}")
    file.write_text(text.replace(old, new))


# --- misc/helpers.h -------------------------------------------------------
# The SkyLight space helpers become calls into the preview shim, and the
# script runner moves to the shim as well.
patch(
    "misc/helpers.h",
    '#include "env_vars.h"\n#include "defines.h"\n#include "extern.h"\n',
    '#include "env_vars.h"\n#include "defines.h"\n#include "preview_shim.h"\n',
)

patch(
    "misc/helpers.h",
    """static inline int mission_control_index(uint64_t sid) {
  uint64_t result = 0;
  int desktop_cnt = 1;

  CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
  int display_spaces_count = CFArrayGetCount(display_spaces_ref);

  for (int i = 0; i < display_spaces_count; ++i) {
    CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
    CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
    int spaces_count = CFArrayGetCount(spaces_ref);

    for (int j = 0; j < spaces_count; ++j) {
      CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
      CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
      CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &result);
      if (sid == result) goto out;

      ++desktop_cnt;
    }
  }

  desktop_cnt = 0;
out:
  CFRelease(display_spaces_ref);
  return desktop_cnt;
}

static inline uint64_t dsid_from_sid(uint32_t sid) {
  uint64_t result = 0;
  int desktop_cnt = 1;

  CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
  int display_spaces_count = CFArrayGetCount(display_spaces_ref);

  for (int i = 0; i < display_spaces_count; ++i) {
    CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
    CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
    int spaces_count = CFArrayGetCount(spaces_ref);

    for (int j = 0; j < spaces_count; ++j) {
      CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
      CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
      CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &result);
      if (sid == desktop_cnt) goto out;

      ++desktop_cnt;
    }
  }

  result = 0;
out:
  CFRelease(display_spaces_ref);
  return result;
}

static inline CGImageRef space_capture(uint32_t sid) {
  uint64_t dsid = dsid_from_sid(sid);
  CGImageRef image = NULL;
  if (dsid) {
    CFArrayRef result = SLSHWCaptureSpace(g_connection, dsid, 0);
    uint32_t count = CFArrayGetCount(result);
    if (count > 0) {
      image = (CGImageRef)CFRetain(CFArrayGetValueAtIndex(result, 0));
    }
    CFRelease(result);
  }
  return image;
}

static inline uint32_t display_id_for_space(uint32_t sid) {
  uint64_t dsid = dsid_from_sid(sid);
  if (!dsid) return 0;
  CFStringRef uuid_string = SLSCopyManagedDisplayForSpace(g_connection, dsid);
  if (!uuid_string) return 0;

  CFUUIDRef uuid = CFUUIDCreateFromString(NULL, uuid_string);
  uint32_t id = CGDisplayGetDisplayIDFromUUID(uuid);

  CFRelease(uuid);
  CFRelease(uuid_string);

  return id;
}
""",
    """static inline int mission_control_index(uint64_t sid) {
  return preview_space_index(sid);
}

static inline uint64_t dsid_from_sid(uint32_t sid) {
  return preview_space_display_id(sid);
}

static inline CGImageRef space_capture(uint32_t sid) {
  return preview_space_capture(sid);
}

static inline uint32_t display_id_for_space(uint32_t sid) {
  return preview_display_id_for_space(sid);
}
""",
)

patch(
    "misc/helpers.h",
    """static inline bool sync_exec(char *command, struct env_vars *env_vars) {
  if (env_vars) {
    for (int i = 0; i < env_vars->count; i++) {
      setenv(env_vars->vars[i]->key, env_vars->vars[i]->value, 1);
    }
  }

  char *exec[] = { "/usr/bin/env", "sh", "-c", command, NULL};
  return execvp(exec[0], exec);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline bool fork_exec(char *command, struct env_vars* env_vars) {
  int pid = vfork();
  if (pid == -1) return false;
  if (pid !=  0) return true;

  alarm(FORK_TIMEOUT);
  exit(sync_exec(command, env_vars));
}
#pragma clang diagnostic pop
""",
    """bool sync_exec(char *command, struct env_vars *env_vars);
bool fork_exec(char *command, struct env_vars *env_vars);
""",
)

# The SkyLight connection id means nothing without a window server.
patch(
    "misc/helpers.h",
    """#define FORK_TIMEOUT 60

extern int g_connection;
""",
    """#define FORK_TIMEOUT 60
""",
)

# The preview runs the scripts of the items with a much shorter timeout than
# the daemon: the preview is interactive, so a script that hangs must not
# hold the app. Three seconds is the value this project chose.
patch(
    "misc/helpers.h",
    """#define MAXLEN 512
#define FORK_TIMEOUT 60
""",
    """#define MAXLEN 512
#define FORK_TIMEOUT 60

/* The preview runs the scripts of the items with a much shorter timeout than
   the daemon: the preview is interactive, so a script that hangs must not
   hold the app. Three seconds is the value this project chose. */
#define PREVIEW_SCRIPT_TIMEOUT 3
""",
)

# respond() copies every answer to stdout, so a rejected property prints a
# line in the app. The preview has no log: the answer goes to the reply
# stream only.
patch(
    "misc/helpers.h",
    """static inline void respond(FILE* rsp, char* response, ...) {
  time_t t = time(NULL);
  struct tm ltime = *localtime(&t);
  printf("[%d-%02d-%02d %02d:%02d:%02d] ",
         ltime.tm_year + 1900,
         ltime.tm_mon + 1,
         ltime.tm_mday,
         ltime.tm_hour,
         ltime.tm_min,
         ltime.tm_sec                     );

  va_list args_rsp;
  va_list args_stdout;
  va_start(args_rsp, response);
  va_copy(args_stdout, args_rsp);
  vfprintf(rsp, response, args_rsp);
  vfprintf(stdout, response, args_stdout);
  va_end(args_rsp);
  va_end(args_stdout);
}
""",
    """static inline void respond(FILE* rsp, char* response, ...) {
  /* The daemon writes every answer to its log as well. The preview has no
     log, and the app would print a line on stdout for every rejected
     property. The answer goes to the reply stream only. */
  va_list args_rsp;
  va_start(args_rsp, response);
  vfprintf(rsp, response, args_rsp);
  va_end(args_rsp);
}
""",
)

# --- event.h: the message machinery is gone -------------------------------
# message.h pulls in mach.h, which declares the Mach bootstrap server the
# preview does not have. display.h takes its place: it carries the display
# declarations the kept code used to reach through message.h.
patch(
    "event.h",
    """#include "bar_manager.h"
#include "message.h"
""",
    """#include "bar_manager.h"
#include "display.h"
""",
)

# --- bar.c / bar_manager.c: the space type --------------------------------
patch(
    "bar.c",
    "  bar->shown = SLSSpaceGetType(g_connection, bar->dsid) != 4;",
    "  bar->shown = preview_space_type(bar->dsid) != PREVIEW_SPACE_TYPE_FULLSCREEN;",
)

# The daemon asks CoreGraphics whether the display is built-in, because the
# notch of a built-in display is part of its layout. The preview has no
# window server, and the id of its virtual display is 1, which is the id of
# the built-in display of a real Mac: the answer would depend on the
# machine. The notch of the virtual display is a parameter of the preview
# (sb_preview_set_notch).
patch(
    "bar.c",
    """static void bar_calculate_bounds_top_bottom(struct bar* bar) {
  bool is_builtin = CGDisplayIsBuiltin(bar->did);
""",
    """static void bar_calculate_bounds_top_bottom(struct bar* bar) {
  /* The preview has no window server: the id of the virtual display is
     1, which is the id of the built-in display of a real Mac, so the answer
     of CoreGraphics would depend on the machine. The notch of the virtual
     display is a parameter of the preview. */
  bool is_builtin = preview_display_has_notch();
""",
)

patch(
    "bar.c",
    """static CGRect bar_get_frame(struct bar *bar) {
  bool is_builtin = CGDisplayIsBuiltin(bar->did);
""",
    """static CGRect bar_get_frame(struct bar *bar) {
  /* The preview has no window server: the id of the virtual display is
     1, which is the id of the built-in display of a real Mac, so the answer
     of CoreGraphics would depend on the machine. The notch of the virtual
     display is a parameter of the preview. */
  bool is_builtin = preview_display_has_notch();
""",
)

patch(
    "bar_manager.c",
    "    bar_manager->bars[i]->shown = SLSSpaceGetType(g_connection, dsid) != 4 || bar_manager->show_in_fullscreen;",
    "    bar_manager->bars[i]->shown = preview_space_type(dsid) != PREVIEW_SPACE_TYPE_FULLSCREEN || bar_manager->show_in_fullscreen;",
)

# --- bar_item.c / bar_item.h / bar_manager.c: the Mach event port ---------
patch(
    "bar_item.c",
    """    // Mach events
    if (bar_item->event_port) {
      uint32_t len = 0;
      char* message = env_vars_copy_serialized_representation(env_vars, &len);

      mach_send_message(bar_item->event_port, message, len, false);
      free(message);
    }
""",
    "",
)

patch(
    "bar_item.c",
    """static void bar_item_set_event_port(struct bar_item* bar_item, char* bs_name) {
  mach_port_t port = mach_get_bs_port(bs_name);
  bar_item->event_port = port;
}

""",
    "",
)

patch(
    "bar_item.c",
    """  } else if (token_equals(property, PROPERTY_EVENT_PORT)) {
    struct token token = get_token(&message);
    if (token.text && token.length > 0)
      bar_item_set_event_port(bar_item, token.text);
""",
    """  } else if (token_equals(property, PROPERTY_EVENT_PORT)) {
    respond(rsp, "[!] Item (%s): The event_port property is not available in the preview\\n", bar_item->name);
""",
)

patch(
    "bar_item.c",
    """  bar_item->blur_radius = 0;
  bar_item->event_port = 0;
""",
    """  bar_item->blur_radius = 0;
""",
)

patch(
    "bar_item.c",
    """    if ((bar_item->script && strlen(bar_item->script) > 0)
         || bar_item->event_port                          ) {
""",
    """    if (bar_item->script && strlen(bar_item->script) > 0) {
""",
)

patch(
    "bar_item.h",
    """  // Popup
  struct popup popup;
  struct bar_item* parent;

  // Mach
  mach_port_t event_port;
};""",
    """  // Popup
  struct popup popup;
  struct bar_item* parent;
};""",
)

patch(
    "bar_manager.c",
    """  for (int i = 0; i < bar_manager->bar_item_count; i++) {
    struct bar_item* bar_item = bar_manager->bar_items[i];
    if (bar_item->event_port) {
      mach_send_message(bar_item->event_port, "k", 2, false);
    }
  }

""",
    "",
)

# --- animation.c: the display link of the daemon ----------------------------
# The display link of the daemon drives the animations from the window
# server. The preview has no window server: the link would only wake the app
# up for nothing. The duration of the animator stays 0, so no animation is
# ever created and the link is never needed.
patch(
    "animation.c",
    """void animator_renew_display_link(struct animator* animator) {
  animator_destroy_display_link(animator);
  CVDisplayLinkCreateWithActiveCGDisplays(&animator->display_link);

  CVDisplayLinkSetOutputCallback(animator->display_link,
                                 animation_frame_callback,
                                 animator                 );

  animator->clock = CVGetHostClockFrequency();
  CVDisplayLinkStart(animator->display_link);
}
""",
    """void animator_renew_display_link(struct animator* animator) {
  animator_destroy_display_link(animator);

  /* The preview has no display link. The daemon drives its animations from
     the display link of the window server, and the preview has no window
     server: the link would only wake the app up for nothing. The duration
     of the animator stays 0, so no animation is ever created and the link
     is never needed. */
  if (animator->display_link) {
    CVDisplayLinkSetOutputCallback(animator->display_link,
                                   animation_frame_callback,
                                   animator                 );

    animator->clock = CVGetHostClockFrequency();
    CVDisplayLinkStart(animator->display_link);
  }
}
""",
)

# --- bar_manager.c: the clock of the daemon ---------------------------------
# The clock of the daemon is a 1 Hz timer on the main run loop of the app.
# The preview never creates it, so the removal of it has to be guarded.
patch(
    "bar_manager.c",
    """  if (bar_manager->bars) free(bar_manager->bars);
  CFRunLoopRemoveTimer(CFRunLoopGetMain(),
                       bar_manager->clock,
                       kCFRunLoopCommonModes);

  CFRunLoopTimerInvalidate(bar_manager->clock);
  CFRelease(bar_manager->clock);
""",
    """  if (bar_manager->bars) free(bar_manager->bars);

  /* The preview never creates the clock of the daemon: it is a 1 Hz timer
     on the main run loop of the app (src/bar_manager.c:67-78). */
  if (bar_manager->clock) {
    CFRunLoopRemoveTimer(CFRunLoopGetMain(),
                         bar_manager->clock,
                         kCFRunLoopCommonModes);

    CFRunLoopTimerInvalidate(bar_manager->clock);
    CFRelease(bar_manager->clock);
    bar_manager->clock = NULL;
  }
""",
)

# --- alias.c: the window server ---------------------------------------------
# The alias item finds the window of a menu bar item with the window server.
# The preview has no window server, and the app must never ask for the Screen
# Recording permission because a config holds an alias item.
patch(
    "alias.c",
    """struct menu_item_list get_menu_item_list() {
  CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll,
                                                      kCGNullWindowID        );
  int window_count = CFArrayGetCount(window_list);

  struct menu_item_list menu_item_list;
  menu_item_list_init(&menu_item_list, window_count);

  int item_count = 0;
  for (int i = 0; i < window_count; ++i) {
    CFDictionaryRef dictionary = CFArrayGetValueAtIndex(window_list, i);
    if (!dictionary) continue;

    CFStringRef owner_ref = CFDictionaryGetValue(dictionary,
                                                 kCGWindowOwnerName);

    CFNumberRef owner_pid_ref = CFDictionaryGetValue(dictionary,
                                                     kCGWindowOwnerPID);

    CFStringRef name_ref = CFDictionaryGetValue(dictionary, kCGWindowName);
    CFNumberRef layer_ref = CFDictionaryGetValue(dictionary, kCGWindowLayer);
    CFDictionaryRef bounds_ref = CFDictionaryGetValue(dictionary,
                                                      kCGWindowBounds);
    CFNumberRef window_id_ref = CFDictionaryGetValue(dictionary,
                                                     kCGWindowNumber);


    if (!name_ref || !owner_ref || !owner_pid_ref || !layer_ref || !bounds_ref
        || !window_id_ref)
      continue;

    long long int layer = 0;
    CFNumberGetValue(layer_ref, CFNumberGetType(layer_ref), &layer);
    uint64_t owner_pid = 0;
    CFNumberGetValue(owner_pid_ref,
                     CFNumberGetType(owner_pid_ref),
                     &owner_pid                     );

    if (layer != MENUBAR_LAYER) continue;
    CGRect bounds = CGRectNull;
    if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds)) continue;
    char* owner_copy = cfstring_copy(owner_ref);
    if (string_equals(owner_copy, "Window Server")) {
      free(owner_copy);
      continue;
    }

    uint64_t wid;
    CFNumberGetValue(window_id_ref,
                     CFNumberGetType(window_id_ref),
                     &wid                           );
    
    struct menu_item* menu_item = menu_item_list.menu_items + item_count++;
    menu_item->owner = owner_copy;
    menu_item->name = cfstring_copy(name_ref);
    menu_item->x_pos = bounds.origin.x;
    menu_item->wid = wid;
    menu_item->layer = layer;
    menu_item->bounds = bounds;
  }

  menu_item_list.menu_item_count = item_count;
  menu_item_list_sort(&menu_item_list);
  CFRelease(window_list);
  return menu_item_list;
}
""",
    """struct menu_item_list get_menu_item_list() {
  /* The preview has no window server. The enumeration of the menu bar items
     would need the Screen Recording permission, and the app must never ask
     for it because a config holds an alias item. The preview has no menu
     bar item to find. */
  struct menu_item_list menu_item_list;
  memset(&menu_item_list, 0, sizeof(menu_item_list));
  return menu_item_list;
}
""",
)

patch(
    "alias.c",
    """void print_all_menu_items(FILE* rsp) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 110000
  if (__builtin_available(macOS 11.0, *)) {
    if (!CGRequestScreenCaptureAccess()) {
      respond(rsp, "[!] Query (default_menu_items): Screen Recording "
                   "Permissions not given. Restart SketchyBar after granting "
                   "permissions.\\n");
      return;
    }
  }

#endif
  struct menu_item_list menu_item_list = get_menu_item_list();
""",
    """void print_all_menu_items(FILE* rsp) {
  struct menu_item_list menu_item_list = get_menu_item_list();
""",
)

patch(
    "alias.c",
    """void alias_get_permission(struct alias* alias) { 
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 110000 
  if (__builtin_available(macOS 11.0, *)) {
    alias->permission = CGRequestScreenCaptureAccess();
  }
#else
  if(__builtin_available(macos 10.15, *)) {
    CGImageRef img = CGWindowListCreateImage(CGRectMake(0, 0, 1, 1),
                                             kCGWindowListOptionOnScreenOnly,
                                             kCGNullWindowID,
                                             kCGWindowImageDefault           );

    CFRelease(img);
  }
#endif
}
""",
    """void alias_get_permission(struct alias* alias) {
  /* The preview never asks for the Screen Recording permission: the app
     must not show a permission prompt because a config holds an alias
     item. The permission stays false, so the alias item draws its
     placeholder. */
  alias->permission = false;
}
""",
)

print(f"vendored subset copied from {UPSTREAM} and patched")
