#include <unistd.h>
#include "misc/helpers.h"
#include "preview_shim.h"

/* The script runner. The daemon runs the script of an item in a child
   process and hands it the environment of the item. The preview keeps the
   same behaviour for stage 1; stage 6 adds the preview environment and the
   PATH shim that captures the --set calls. */

bool sync_exec(char* command, struct env_vars* env_vars) {
  if (env_vars) {
    for (int i = 0; i < env_vars->count; i++) {
      setenv(env_vars->vars[i]->key, env_vars->vars[i]->value, 1);
    }
  }

  char* exec[] = { "/usr/bin/env", "sh", "-c", command, NULL };
  return execvp(exec[0], exec);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool fork_exec(char* command, struct env_vars* env_vars) {
  int pid = vfork();
  if (pid == -1) return false;
  if (pid != 0) return true;

  alarm(FORK_TIMEOUT);
  exit(sync_exec(command, env_vars));
}
#pragma clang diagnostic pop
