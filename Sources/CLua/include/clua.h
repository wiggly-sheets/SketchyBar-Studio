/*
** The public C API of the vendored Lua interpreter.
**
** The interpreter itself is the vendored Lua 5.5.0 (see UPSTREAM.md). This
** header exposes only what the Swift wrapper needs: a state with a bounded
** allocator, a deadline and a sandbox, and the two ways to run Lua in it.
**
** This is a GUARD for a config the user owns, not a security boundary. See
** Sources/CLua/clua.c for the rules of the sandbox.
*/

#ifndef CLUA_H
#define CLUA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* An opaque Lua state. */
typedef struct CLuaState CLuaState;

/*
** Creates a state with the sandbox of the preview.
**
** memoryLimitBytes is the hard cap of the allocator: an allocation that
** would grow the state past the cap fails, so Lua raises a memory error
** instead of taking the machine with it.
**
** timeoutSeconds is the deadline of one run: the count hook of the state
** aborts the run when the deadline passes.
**
** Returns NULL when the state cannot be created.
*/
CLuaState *clua_create(size_t memoryLimitBytes, double timeoutSeconds);

/* Closes a state and frees everything it owns. Passing NULL is a no-op. */
void clua_destroy(CLuaState *state);

/*
** Runs a Lua file in the state.
**
** The file is read with the loader of Lua, so a shebang line is skipped.
** The path and the chunk name are the two arguments.
**
** Returns 0 when the file ran. On a failure it returns 1 and writes the
** message of the error into errorBuffer (truncated to errorBufferSize).
*/
int clua_run_file(CLuaState *state,
                  const char *path,
                  const char *chunkName,
                  char *errorBuffer,
                  size_t errorBufferSize);

/*
** Runs a chunk of Lua source in the state.
**
** Returns 0 when the chunk ran. On a failure it returns 1 and writes the
** message of the error into errorBuffer.
*/
int clua_run_string(CLuaState *state,
                    const char *source,
                    const char *chunkName,
                    char *errorBuffer,
                    size_t errorBufferSize);

/*
** Sets a global of the state to a string.
**
** The string is copied into the state, so the caller keeps its buffer.
*/
void clua_set_global_string(CLuaState *state, const char *name, const char *value);

/*
** The value of a global of the state as a C string.
**
** The pointer belongs to the state and stays valid until the state is
** closed. Returns NULL when the global does not exist or is not a string.
*/
const char *clua_global_string(CLuaState *state, const char *name);

/* The number of bytes the state has allocated. */
size_t clua_memory_used(const CLuaState *state);

/* True when the last run was aborted by the deadline. */
int clua_timed_out(const CLuaState *state);

#ifdef __cplusplus
}
#endif

#endif /* CLUA_H */
