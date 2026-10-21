/*
** The wrapper of the vendored Lua interpreter.
**
** The interpreter is the vendored Lua 5.5.0 (see UPSTREAM.md). This file
** adds the guards the preview needs and nothing else:
**
**   - a custom allocator with a hard cap, so a runaway allocation raises a
**     Lua error instead of eating the machine;
**   - a count hook with a deadline, so an endless loop aborts with an
**     error instead of hanging the app;
**   - a sandbox that removes the globals a config must not use.
**
** The sandbox rules themselves live in the Lua bootstrap of the app
** (Sources/SketchyBarStudio/Support/LuaConfigRunner.swift), because they
** are easier to read and to change there.
**
** THIS IS A GUARD, NOT A SECURITY BOUNDARY. The state runs the Lua of a
** config the user owns, in the app, with the app's rights. The rules cut
** the ways a config can reach the machine (a shell, a write, a C module),
** but a determined script can still find a way out of a Lua sandbox.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "clua.h"

/* The number of VM instructions between two checks of the deadline. */
#define CLUA_HOOK_COUNT 10000

struct CLuaState {
    lua_State *lua;
    size_t memoryLimit;
    size_t memoryUsed;
    double timeoutSeconds;
    struct timespec deadline;
    int timedOut;
};

/*
** The allocator of the state.
**
** The contract of Lua: osize is the size of the old block when ptr is not
** NULL, and the type of the new object when ptr is NULL. nsize of zero
** means "free this block".
**
** An allocation that would grow the state past the cap fails, so Lua raises
** a memory error instead of taking the machine with it.
*/
static void *clua_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    struct CLuaState *state = (struct CLuaState *)ud;
    size_t old = (ptr == NULL) ? 0 : osize;
    size_t used = state->memoryUsed;

    if (nsize == 0) {
        free(ptr);
        state->memoryUsed = (used >= old) ? used - old : 0;
        return NULL;
    }

    if (used < old) old = used;
    if (nsize > state->memoryLimit || used - old > state->memoryLimit - nsize) {
        return NULL;
    }

    void *next = realloc(ptr, nsize);
    if (next == NULL) return NULL;

    state->memoryUsed = used - old + nsize;
    return next;
}

/*
** The count hook of the state.
**
** The hook checks the deadline of the run. When the deadline has passed it
** raises a Lua error, so the run aborts with a message instead of hanging.
*/
static void clua_hook(lua_State *lua, lua_Debug *debug) {
    (void)debug;
    struct CLuaState *state = *(struct CLuaState **)lua_getextraspace(lua);
    if (state == NULL) return;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    double elapsed = (double)(now.tv_sec - state->deadline.tv_sec);
    elapsed += (double)(now.tv_nsec - state->deadline.tv_nsec) / 1e9;

    if (elapsed >= 0.0) {
        state->timedOut = 1;
        luaL_error(lua, "the Lua config ran for more than %f seconds",
                   state->timeoutSeconds);
    }
}

/*
** Starts the deadline of the state.
**
** The deadline is the budget of the WHOLE state and not of a call: a run
** that needs several files cannot buy more time with another call, and a
** future multi-file API gives every file the same window.
*/
static void clua_start_deadline(struct CLuaState *state) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    state->deadline = now;
    state->deadline.tv_sec += (time_t)state->timeoutSeconds;
    state->timedOut = 0;
}

CLuaState *clua_create(size_t memoryLimitBytes, double timeoutSeconds) {
    struct CLuaState *state = (struct CLuaState *)calloc(1, sizeof(struct CLuaState));
    if (state == NULL) return NULL;

    state->memoryLimit = memoryLimitBytes;
    state->timeoutSeconds = timeoutSeconds;
    /* The seed of Lua 5.5 randomizes the hashes of the strings and the
       tables. The preview uses a fixed seed, so the same config always
       produces the same result. */
    state->lua = lua_newstate(clua_alloc, state, 0);
    if (state->lua == NULL) {
        free(state);
        return NULL;
    }

    *(struct CLuaState **)lua_getextraspace(state->lua) = state;

    luaL_openlibs(state->lua);
    lua_sethook(state->lua, clua_hook, LUA_MASKCOUNT, CLUA_HOOK_COUNT);

    /* The deadline starts with the state, so it covers every call the
       state makes. */
    clua_start_deadline(state);

    return state;
}

void clua_destroy(CLuaState *state) {
    if (state == NULL) return;
    if (state->lua != NULL) lua_close(state->lua);
    state->lua = NULL;
    free(state);
}

/* Copies the message of the error of the state into the buffer. */
static void clua_copy_error(lua_State *lua, char *buffer, size_t size) {
    if (buffer == NULL || size == 0) return;
    const char *message = lua_tostring(lua, -1);
    if (message == NULL) message = "the Lua config failed";
    snprintf(buffer, size, "%s", message);
    lua_pop(lua, 1);
}

int clua_run_file(CLuaState *state,
                  const char *path,
                  const char *chunkName,
                  char *errorBuffer,
                  size_t errorBufferSize) {
    if (state == NULL || path == NULL) return 1;

    if (luaL_loadfile(state->lua, path) != LUA_OK) {
        clua_copy_error(state->lua, errorBuffer, errorBufferSize);
        return 1;
    }

    if (lua_pcall(state->lua, 0, 0, 0) != LUA_OK) {
        clua_copy_error(state->lua, errorBuffer, errorBufferSize);
        return 1;
    }

    return 0;
}

int clua_run_string(CLuaState *state,
                    const char *source,
                    const char *chunkName,
                    char *errorBuffer,
                    size_t errorBufferSize) {
    if (state == NULL || source == NULL) return 1;

    if (luaL_loadbuffer(state->lua, source, strlen(source),
                        chunkName ? chunkName : "=(load)") != LUA_OK) {
        clua_copy_error(state->lua, errorBuffer, errorBufferSize);
        return 1;
    }

    if (lua_pcall(state->lua, 0, 0, 0) != LUA_OK) {
        clua_copy_error(state->lua, errorBuffer, errorBufferSize);
        return 1;
    }

    return 0;
}

void clua_set_global_string(CLuaState *state, const char *name, const char *value) {
    if (state == NULL || name == NULL) return;
    lua_pushstring(state->lua, value ? value : "");
    lua_setglobal(state->lua, name);
}

const char *clua_global_string(CLuaState *state, const char *name) {
    if (state == NULL || name == NULL) return NULL;

    lua_getglobal(state->lua, name);
    if (lua_type(state->lua, -1) != LUA_TSTRING) {
        lua_pop(state->lua, 1);
        return NULL;
    }

    /* The value stays on the stack, so the pointer stays valid until the
       state is closed. */
    return lua_tostring(state->lua, -1);
}

size_t clua_memory_used(const CLuaState *state) {
    return state ? state->memoryUsed : 0;
}

int clua_timed_out(const CLuaState *state) {
    return state ? state->timedOut : 0;
}
