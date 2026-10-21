#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
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
   it talks to the real daemon.

   The child of a script of the preview gets a PATH whose first entry is the
   directory of the shim, so a script that calls `sketchybar` reaches the
   shim and writes to the sink of the preview instead of the live bar. The
   directories that hold a real sketchybar are removed from the PATH, so a
   script that resolves the binary by name cannot reach the daemon either.
   A script that calls the binary by its absolute path is not intercepted:
   that is a known limit of the preview, and the preview warns about it. */

extern char** environ;

#define PREVIEW_BAR_NAME "BAR_NAME"
#define PREVIEW_MARKER_NAME "SKETCHYBAR_PREVIEW"
#define PREVIEW_MARKER_VALUE "1"

/* The name of the binary the scripts call. The shim of the preview has that
   name and stands in for the binary of the daemon. */
#define PREVIEW_BINARY_NAME "sketchybar"

/* The variable that carries the path of the sink file to the shim. */
#define PREVIEW_SINK_VARIABLE "SKETCHYBAR_STUDIO_PREVIEW_SINK"

/* The longest path the preview builds. */
#define PREVIEW_PATH_MAX 4096

/* The margin between the alarm of the child and the kill of the parent.

   The alarm of the child is the first line of defence: the child stops
   itself when the script runs too long. The kill of the parent is the
   second one, for a script that ignores the alarm. */
#define PREVIEW_SCRIPT_MARGIN_MS 500

/* The directories the child needs whatever the script does: the shell is
   resolved through the PATH, because the child runs /usr/bin/env sh -c. */
#define PREVIEW_REQUIRED_PATH "/bin"
#define PREVIEW_REQUIRED_PATH_ALT "/usr/bin"

/* --- The environment of the scripts -------------------------------------- */

/* The directory of the shim, the path of the sink file and the directory of
   the log files. The preview sets them before it runs the scripts, and the
   child of every script gets them. */
static char* g_preview_shim_directory = NULL;
static char* g_preview_sink_path = NULL;
static char* g_preview_log_directory = NULL;

/* The alias of the script that is forked next. The caller sets it before it
   forks, so the report of a script knows the item it belongs to. */
static char* g_preview_current_alias = NULL;

/* The number of the scripts that were forked. It names the log files. */
static unsigned g_preview_script_index = 0;

/* The number of the children that could not be forked. The preview says
   so, because a script that does not start is a script that does not run.
   The count is read and cleared by the wait, which runs after the forks. */
static unsigned g_preview_fork_failures = 0;

/* The messages of the last run of the scripts and its outcome. */
static char* g_preview_script_messages = NULL;
static int g_preview_script_status = PREVIEW_SCRIPT_OUTCOME_OK;

/* The children of the scripts that have not been reported yet. */
struct preview_child {
  pid_t pid;
  char* alias;
  char* log_path;
  int status;
  bool finished;
  bool timed_out;
};

static struct preview_child* g_preview_children = NULL;
static size_t g_preview_child_count = 0;
static size_t g_preview_child_capacity = 0;

/* --- The small helpers ---------------------------------------------------- */

static bool preview_entry_has_key(const char* entry, const char* key) {
  size_t length = strlen(key);
  return strncmp(entry, key, length) == 0 && entry[length] == '=';
}

static char* preview_copy_string(const char* text) {
  if (!text) return NULL;
  size_t length = strlen(text);
  char* copy = malloc(length + 1);
  if (!copy) return NULL;
  memcpy(copy, text, length + 1);
  return copy;
}

static void preview_free_string(char** text) {
  if (!text || !*text) return;
  free(*text);
  *text = NULL;
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

/* The value of one entry of the environment, or NULL when the environment
   does not hold that key. */
static const char* preview_environment_value(char** environment,
                                              size_t count,
                                              const char* key) {
  size_t length = strlen(key);
  for (size_t i = 0; i < count; i++) {
    if (preview_entry_has_key(environment[i], key)) return environment[i] + length + 1;
  }
  return NULL;
}

/* Puts one entry into the environment, replacing the entry of that key. */
static bool preview_environment_set(char*** environment,
                                     size_t* count,
                                     size_t* capacity,
                                     const char* key,
                                     const char* value) {
  preview_environment_remove(environment, count, key);

  size_t length = strlen(key) + strlen(value) + 2;
  char* entry = malloc(length);
  if (!entry) return false;
  snprintf(entry, length, "%s=%s", key, value);

  if (!preview_environment_grow(environment, count, capacity)) {
    free(entry);
    return false;
  }
  (*environment)[(*count)++] = entry;
  return true;
}

/* --- The PATH of the child ------------------------------------------------ */

/* Appends text to the PATH that is being built. */
static char* preview_path_append(char* path,
                                 size_t* length,
                                 size_t* capacity,
                                 const char* text) {
  size_t text_length = strlen(text);
  if (*length + text_length + 1 > *capacity) {
    size_t grown = *capacity ? *capacity : 256;
    while (grown < *length + text_length + 1) grown *= 2;
    char* bigger = realloc(path, grown);
    if (!bigger) return NULL;
    path = bigger;
    *capacity = grown;
  }

  memcpy(path + *length, text, text_length);
  *length += text_length;
  path[*length] = '\0';
  return path;
}

/* Appends text to the PATH that is being built. The buffer may move, so the
   caller keeps the pointer through this one. */
static bool preview_path_add(char** path,
                             size_t* length,
                             size_t* capacity,
                             const char* text) {
  char* grown = preview_path_append(*path, length, capacity, text);
  if (!grown) return false;
  *path = grown;
  return true;
}

/* Whether a directory holds a file called "sketchybar".
   A directory that holds one is removed from the PATH of the child, so a
   script that resolves the binary by name cannot reach the real daemon.

   Only a regular file counts: a directory or a socket called
   "sketchybar" cannot be run, so the entry stays on the PATH. A stat that
   fails with anything else than "no such file" means that the preview
   cannot tell, and the conservative answer is that the directory holds a
   binary: the entry is removed then. */
static bool preview_directory_holds_binary(const char* directory) {
  if (!directory || !*directory) return false;

  char path[PREVIEW_PATH_MAX];
  int length = snprintf(path, sizeof(path), "%s/%s", directory, PREVIEW_BINARY_NAME);
  if (length < 0 || length >= (int)sizeof(path)) return true;

  struct stat buffer;
  if (stat(path, &buffer) != 0) return errno != ENOENT;
  return S_ISREG(buffer.st_mode);
}

/* Whether the PATH holds that directory as one of its entries. */
static bool preview_path_has_entry(const char* path, const char* entry) {
  if (!path) return false;
  size_t length = strlen(entry);

  const char* cursor = path;
  while (*cursor) {
    const char* colon = strchr(cursor, ':');
    size_t size = colon ? (size_t)(colon - cursor) : strlen(cursor);
    if (size == length && strncmp(cursor, entry, length) == 0) return true;
    if (!colon) break;
    cursor = colon + 1;
  }
  return false;
}

/* The PATH of the child: the directory of the shim first, then the
   directories of the PATH of the app without the ones that hold a real
   sketchybar, then the directories the shell needs.

   The child runs /usr/bin/env sh -c, and env resolves the shell through the
   PATH, so a PATH without a shell means no script at all. */
static char* preview_build_path(const char* original) {
  size_t capacity = 256;
  size_t length = 0;
  char* path = malloc(capacity);
  if (!path) return NULL;
  path[0] = '\0';

  if (!preview_path_add(&path, &length, &capacity, g_preview_shim_directory)) {
    free(path);
    return NULL;
  }

  if (original) {
    const char* cursor = original;
    while (*cursor) {
      const char* colon = strchr(cursor, ':');
      size_t size = colon ? (size_t)(colon - cursor) : strlen(cursor);
      if (size > 0 && size < PREVIEW_PATH_MAX) {
        char entry[PREVIEW_PATH_MAX];
        memcpy(entry, cursor, size);
        entry[size] = '\0';

        if (!preview_directory_holds_binary(entry)) {
          if (!preview_path_add(&path, &length, &capacity, ":") ||
              !preview_path_add(&path, &length, &capacity, entry)) {
            free(path);
            return NULL;
          }
        }
      }
      if (!colon) break;
      cursor = colon + 1;
    }
  }

  if (!preview_path_has_entry(path, PREVIEW_REQUIRED_PATH)) {
    if (!preview_path_add(&path, &length, &capacity, ":") ||
        !preview_path_add(&path, &length, &capacity, PREVIEW_REQUIRED_PATH)) {
      free(path);
      return NULL;
    }
  }
  if (!preview_path_has_entry(path, PREVIEW_REQUIRED_PATH_ALT)) {
    if (!preview_path_add(&path, &length, &capacity, ":") ||
        !preview_path_add(&path, &length, &capacity, PREVIEW_REQUIRED_PATH_ALT)) {
      free(path);
      return NULL;
    }
  }

  return path;
}

/* --- The environment of the child ----------------------------------------- */

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

  /* The PATH of the child and the sink of the shim. They are only set when
     the preview installed the shim, so the environment of a child that runs
     without the shim stays the environment of the app. */
  if (g_preview_shim_directory) {
    char* path = preview_build_path(preview_environment_value(environment, count, "PATH"));
    if (!path) goto failed;

    bool set = preview_environment_set(&environment, &count, &capacity, "PATH", path);
    free(path);
    if (!set) goto failed;

    if (!preview_environment_set(&environment,
                                 &count,
                                 &capacity,
                                 PREVIEW_SINK_VARIABLE,
                                 g_preview_sink_path ? g_preview_sink_path : "")) {
      goto failed;
    }
  }

  if (!preview_environment_grow(&environment, &count, &capacity)) goto failed;
  environment[count] = NULL;
  return environment;

failed:
  for (size_t i = 0; i < count; i++) free(environment[i]);
  free(environment);
  return NULL;
}

/* --- The scripts of the preview ------------------------------------------- */

void preview_set_script_environment(const char* shim_directory,
                                    const char* sink_path,
                                    const char* log_directory) {
  preview_free_string(&g_preview_shim_directory);
  preview_free_string(&g_preview_sink_path);
  preview_free_string(&g_preview_log_directory);

  g_preview_shim_directory = preview_copy_string(shim_directory);
  g_preview_sink_path = preview_copy_string(sink_path);
  g_preview_log_directory = preview_copy_string(log_directory);
}

void preview_set_current_script(const char* alias) {
  preview_free_string(&g_preview_current_alias);
  g_preview_current_alias = preview_copy_string(alias);
}

const char* preview_script_messages(void) {
  return g_preview_script_messages ? g_preview_script_messages : "";
}

int preview_script_status(void) {
  return g_preview_script_status;
}

static void preview_clear_messages(void) {
  preview_free_string(&g_preview_script_messages);
}

static void preview_add_message(const char* format, ...) {
  va_list args;
  va_start(args, format);

  va_list measure;
  va_copy(measure, args);
  int length = vsnprintf(NULL, 0, format, measure);
  va_end(measure);

  if (length < 0) {
    va_end(args);
    return;
  }

  size_t current = g_preview_script_messages ? strlen(g_preview_script_messages) : 0;
  char* grown = realloc(g_preview_script_messages, current + (size_t)length + 1);
  if (!grown) {
    va_end(args);
    return;
  }
  g_preview_script_messages = grown;

  vsnprintf(g_preview_script_messages + current, (size_t)length + 1, format, args);
  va_end(args);
}

/* The text of a file, or NULL when the file cannot be read.
   The whole file is read: a log that is cut in the middle of a line loses
   the message of the script. */
static char* preview_read_file(const char* path) {
  if (!path) return NULL;

  FILE* file = fopen(path, "r");
  if (!file) return NULL;

  size_t capacity = 1024;
  size_t length = 0;
  char* text = malloc(capacity);
  if (!text) {
    fclose(file);
    return NULL;
  }

  while (true) {
    if (length + 1 >= capacity) {
      size_t grown = capacity * 2;
      char* bigger = realloc(text, grown);
      if (!bigger) break;
      text = bigger;
      capacity = grown;
    }

    size_t read = fread(text + length, 1, capacity - length - 1, file);
    length += read;
    if (read == 0) break;
  }

  fclose(file);
  text[length] = '\0';
  return text;
}

/* Keeps the child of a script, so the preview can wait for it and report
   what happened. */
static void preview_track_child(pid_t pid, const char* log_path) {
  if (g_preview_child_count == g_preview_child_capacity) {
    size_t capacity = g_preview_child_capacity ? g_preview_child_capacity * 2 : 16;
    struct preview_child* grown = realloc(g_preview_children,
                                          sizeof(struct preview_child) * capacity);
    if (!grown) return;
    g_preview_children = grown;
    g_preview_child_capacity = capacity;
  }

  struct preview_child* child = &g_preview_children[g_preview_child_count];
  child->pid = pid;
  child->alias = preview_copy_string(g_preview_current_alias);
  child->log_path = preview_copy_string(log_path);
  child->status = 0;
  child->finished = false;
  child->timed_out = false;
  g_preview_child_count++;
}

static uint64_t preview_now_milliseconds(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000 + (uint64_t)(now.tv_nsec / 1000000);
}

static void preview_free_children(void) {
  for (size_t i = 0; i < g_preview_child_count; i++) {
    free(g_preview_children[i].alias);
    free(g_preview_children[i].log_path);
  }
  free(g_preview_children);
  g_preview_children = NULL;
  g_preview_child_count = 0;
  g_preview_child_capacity = 0;
}

/* Waits for the children of the scripts and reports what happened.

   The alarm of the child stops a script that runs too long: the child dies
   with SIGALRM, and the report says the script was stopped. A script that
   ignores the alarm is killed by the parent when the deadline is over. */
void preview_wait_for_scripts(int timeout_milliseconds) {
  /* The margin is the time between the alarm of the child and the kill of
     the parent: the alarm of the child is the first line of defence, and
     the child reports that it was stopped by the alarm. */
  uint64_t deadline = preview_now_milliseconds()
                      + (uint64_t)timeout_milliseconds
                      + PREVIEW_SCRIPT_MARGIN_MS;
  preview_clear_messages();
  g_preview_script_status = PREVIEW_SCRIPT_OUTCOME_OK;

  while (g_preview_child_count > 0) {
    bool all_finished = true;

    for (size_t i = 0; i < g_preview_child_count; i++) {
      if (g_preview_children[i].finished) continue;

      int status = 0;
      pid_t result = waitpid(g_preview_children[i].pid, &status, WNOHANG);
      if (result == g_preview_children[i].pid || (result == -1 && errno == ECHILD)) {
        g_preview_children[i].status = status;
        g_preview_children[i].finished = true;
        g_preview_children[i].timed_out = WIFSIGNALED(status)
                                         && (WTERMSIG(status) == SIGALRM
                                             || WTERMSIG(status) == SIGKILL);
      } else {
        all_finished = false;
      }
    }

    if (all_finished) break;

    if (preview_now_milliseconds() >= deadline) {
      for (size_t i = 0; i < g_preview_child_count; i++) {
        if (!g_preview_children[i].finished) kill(g_preview_children[i].pid, SIGKILL);
      }
      for (size_t i = 0; i < g_preview_child_count; i++) {
        if (g_preview_children[i].finished) continue;
        int status = 0;
        waitpid(g_preview_children[i].pid, &status, 0);
        g_preview_children[i].status = status;
        g_preview_children[i].finished = true;
        g_preview_children[i].timed_out = true;
      }
      break;
    }

    usleep(10000);
  }

  for (size_t i = 0; i < g_preview_child_count; i++) {
    struct preview_child* child = &g_preview_children[i];
    const char* alias = child->alias ? child->alias : "?";

    if (child->timed_out) {
      preview_add_message("The script of the item '%s' did not finish within %d seconds and was stopped.\n",
                          alias,
                          PREVIEW_SCRIPT_TIMEOUT         );
      if (g_preview_script_status == PREVIEW_SCRIPT_OUTCOME_OK) g_preview_script_status = PREVIEW_SCRIPT_OUTCOME_TIMEOUT;
    } else {
      int code = WIFEXITED(child->status) ? WEXITSTATUS(child->status) : -1;
      if (code != 0) {
        preview_add_message("The script of the item '%s' failed with the code %d.\n",
                            alias,
                            code                          );
        if (g_preview_script_status == PREVIEW_SCRIPT_OUTCOME_OK) g_preview_script_status = PREVIEW_SCRIPT_OUTCOME_FAILED;
      }
    }

    /* The script wrote to its standard error or to its standard output:
       the shim reports a command it does not handle there, and a script
       that succeeds but complains says so there too. The message is read
       whatever the exit code is, so a complaint of a script that succeeded
       is not lost. */
    char* text = preview_read_file(child->log_path);
    if (text) {
      if (*text) preview_add_message("%s", text);
      free(text);
    }
  }

  /* The children that could not be forked: the script did not run at all,
     and the preview says so instead of showing a bar without the value. */
  unsigned failures = g_preview_fork_failures;
  g_preview_fork_failures = 0;
  if (failures > 0) {
    preview_add_message("%u script(s) of the items could not be started.\n", failures);
    if (g_preview_script_status == PREVIEW_SCRIPT_OUTCOME_OK) g_preview_script_status = PREVIEW_SCRIPT_OUTCOME_FAILED;
  }

  preview_free_children();
}

/* Runs several scripts the way the daemon runs the script of an item: the
   same child, the same environment, the same timeout.

   Every child is forked first and the wait happens once, in the caller:
   the whole batch has one deadline, so N scripts that hang cost one
   timeout and not N of them. */
bool preview_run_scripts(char** aliases, char** scripts, size_t count) {
  if (!aliases || !scripts) return false;

  bool started = true;
  for (size_t i = 0; i < count; i++) {
    const char* alias = aliases[i];
    const char* script = scripts[i];
    if (!alias || !script) continue;

    preview_set_current_script(alias);

    struct env_vars env_vars;
    env_vars_init(&env_vars);
    env_vars_set(&env_vars, string_copy("NAME"), string_copy((char*)alias));
    env_vars_set(&env_vars, string_copy("SENDER"), string_copy("routine"));

    bool forked = fork_exec((char*)script, &env_vars);
    env_vars_destroy(&env_vars);
    if (!forked) started = false;
  }

  return started;
}

/* --- The child of the script ---------------------------------------------- */

bool sync_exec(char* command, struct env_vars* env_vars) {
  /* The daemon runs the command in the current process and replaces it
     (src/misc/helpers.h:441-447). The preview must never replace the app,
     so the command runs in a child and the parent waits for it. */
  if (!command) return false;

  char** environment = preview_build_environment(env_vars);
  if (!environment) return false;

  pid_t pid = fork();
  if (pid == -1) {
    preview_free_environment(environment);
    return false;
  }
  if (pid == 0) {
    char* arguments[] = { "/usr/bin/env", "sh", "-c", command, NULL };
    execve(arguments[0], arguments, environment);
    _exit(127);
  }

  preview_free_environment(environment);

  int status = 0;
  while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}

  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

bool fork_exec(char* command, struct env_vars* env_vars) {
  /* The environment is built in the parent: the child of a forked process
     must not call malloc, because the allocator of a multithreaded process
     can be locked by another thread at the moment of the fork, and the
     child would deadlock on that lock. The child only calls the functions
     that are safe in a signal handler. */
  char** environment = preview_build_environment(env_vars);
  if (!environment) return false;

  /* The log of the script: the child writes its standard error and its
     standard output there, so the preview can show what the script said.
     The file is opened in the parent, because the child must not open
     files. */
  char log_path[PREVIEW_PATH_MAX];
  int log_fd = -1;
  log_path[0] = '\0';
  if (g_preview_log_directory) {
    snprintf(log_path,
             sizeof(log_path),
             "%s/script-%u.log",
             g_preview_log_directory,
             g_preview_script_index++  );
    log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (log_fd < 0) log_path[0] = '\0';
  }

  pid_t pid = fork();
  if (pid == -1) {
    preview_free_environment(environment);
    if (log_fd >= 0) close(log_fd);
    g_preview_fork_failures++;
    return false;
  }
  if (pid != 0) {
    preview_free_environment(environment);
    if (log_fd >= 0) close(log_fd);
    preview_track_child(pid, log_path[0] ? log_path : NULL);
    return true;
  }

  if (log_fd >= 0) {
    dup2(log_fd, STDERR_FILENO);
    dup2(log_fd, STDOUT_FILENO);
    if (log_fd > STDERR_FILENO) close(log_fd);
  }

  /* The alarm stops the script when it runs too long. The default action
     of the signal terminates the child, so the preview sees that the script
     did not finish. The disposition is set again, because a process that
     ignores the alarm would pass that on to the script. */
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  sigaction(SIGALRM, &action, NULL);
  alarm(PREVIEW_SCRIPT_TIMEOUT);

  execve("/usr/bin/env",
         (char*[]) { "/usr/bin/env", "sh", "-c", command, NULL },
         environment);
  _exit(127);
}
