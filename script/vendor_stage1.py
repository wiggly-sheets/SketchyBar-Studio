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

print(f"vendored subset copied from {UPSTREAM} and patched")
