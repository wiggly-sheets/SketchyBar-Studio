#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "misc/helpers.h"
#include "preview_shim.h"

/* The script runner. The daemon runs the script of an item in a child
   process and hands it the environment of the item (src/misc/helpers.h:441-461).

   The preview builds the environment of the child and hands it over with
   execve, so the environment of the app is never changed. The daemon sets
   the variables in the parent with setenv (src/misc/helpers.h:442-446), and
   that would change the environment of SketchyBar Studio itself. The daemon
   also runs the child with vfork, whose child may not touch the memory of
   the parent; the preview forks.

   The child never gets BAR_NAME. The daemon sets it for its own children
   (src/sketchybar.c:208), and a script of the preview must never believe
   it talks to the real daemon. */

extern char** environ;

#define PREVIEW_BAR_NAME "BAR_NAME"
#define PREVIEW_MARKER_NAME "SKETCHYBAR_PREVIEW"
#define PREVIEW_MARKER_VALUE "1"

static bool preview_entry_has_key(const char* entry, const char* key) {
  size_t length = strlen(key);
  return strncmp(entry, key, length) == 0 && entry[length] == '=';
}

static bool preview_environment_grow(char*** environment,
                                     size_t* count,
                                     size_t* capacity) {
  if (*count + 1 > *capacity) {
    size_t grown_capacity = *capacity ? *capacity * 2 : 64;
    char** grown = realloc(*environment, sizeof(char*) * grown_capacity);
    if (!grown) return false;
    *environment = grown;
    *capacity = grown_capacity;
  }
  return true;
}

static bool preview_environment_add(char*** environment,
                                    size_t* count,
                                    size_t* capacity,
                                    const char* entry) {
  if (!preview_environment_grow(environment, count, capacity)) return false;
  char* copy = malloc(strlen(entry) + 1);
  if (!copy) return false;
  strcpy(copy, entry);
  (*environment)[(*count)++] = copy;
  return true;
}

static void preview_environment_remove(char*** environment,
                                       size_t* count,
                                       const char* key) {
  size_t kept = 0;
  for (size_t i = 0; i < *count; i++) {
    if (preview_entry_has_key((*environment)[i], key)) {
      free((*environment)[i]);
      continue;
    }
    (*environment)[kept++] = (*environment)[i];
  }
  *count = kept;
}

void preview_free_environment(char** environment) {
  if (!environment) return;
  for (size_t i = 0; environment[i]; i++) free(environment[i]);
  free(environment);
}

char** preview_build_environment(struct env_vars* env_vars) {
  char** environment = NULL;
  size_t count = 0;
  size_t capacity = 0;

  for (char** entry = environ; entry && *entry; entry++) {
    if (preview_entry_has_key(*entry, PREVIEW_BAR_NAME)) continue;
    if (!preview_environment_add(&environment, &count, &capacity, *entry)) {
      goto failed;
    }
  }

  if (env_vars) {
    for (uint32_t i = 0; i < env_vars->count; i++) {
      char* key = env_vars->vars[i]->key;
      char* value = env_vars->vars[i]->value;
      if (!key) continue;
      if (strcmp(key, PREVIEW_BAR_NAME) == 0) continue;

      preview_environment_remove(&environment, &count, key);

      size_t length = strlen(key) + (value ? strlen(value) : 0) + 2;
      char* entry = malloc(length);
      if (!entry) goto failed;
      snprintf(entry, length, "%s=%s", key, value ? value : "");
      if (!preview_environment_grow(&environment, &count, &capacity)) {
        free(entry);
        goto failed;
      }
      environment[count++] = entry;
    }
  }

  preview_environment_remove(&environment, &count, PREVIEW_MARKER_NAME);
  if (!preview_environment_add(&environment,
                               &count,
                               &capacity,
                               PREVIEW_MARKER_NAME "=" PREVIEW_MARKER_VALUE)) {
    goto failed;
  }

  if (!preview_environment_grow(&environment, &count, &capacity)) goto failed;
  environment[count] = NULL;
  return environment;

failed:
  for (size_t i = 0; i < count; i++) free(environment[i]);
  free(environment);
  return NULL;
}

static void preview_exec(char* command, struct env_vars* env_vars) {
  char** environment = preview_build_environment(env_vars);
  if (!environment) return;

  char* arguments[] = { "/usr/bin/env", "sh", "-c", command, NULL };
  execve(arguments[0], arguments, environment);
}

bool sync_exec(char* command, struct env_vars* env_vars) {
  preview_exec(command, env_vars);
  return false;
}

bool fork_exec(char* command, struct env_vars* env_vars) {
  /* The environment is built in the parent: the child of a forked process
     must not call malloc, because the allocator of a multithreaded process
     can be locked by another thread at the moment of the fork, and the
     child would deadlock on that lock. The child only calls the functions
     that are safe in a signal handler. */
  char** environment = preview_build_environment(env_vars);
  if (!environment) return false;

  pid_t pid = fork();
  if (pid == -1) {
    preview_free_environment(environment);
    return false;
  }
  if (pid != 0) {
    preview_free_environment(environment);
    return true;
  }

  alarm(FORK_TIMEOUT);
  execve("/usr/bin/env",
         (char*[]) { "/usr/bin/env", "sh", "-c", command, NULL },
         environment);
  _exit(127);
}
