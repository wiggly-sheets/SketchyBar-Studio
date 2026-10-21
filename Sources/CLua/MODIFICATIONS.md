# Modifications to the vendored code

## The sources in `lua/`

**None.** Every file in `lua/` is byte-identical to the upstream Lua 5.5.0
release. The comparison is:

```bash
for f in Sources/CLua/lua/*.c Sources/CLua/lua/*.h; do
  cmp "$f" "<upstream>/lua-5.5.0/src/$(basename "$f")" || echo "differs: $f"
done
```

The only files that are missing are `lua.c` and `luac.c`, the two
standalone programs of the upstream `src` directory. They are not part of
the library and the app has no use for them.

## The files of this target

`clua.c` and `include/clua.h` are new code of this project. They are not
upstream code and they do not change the upstream sources.

`clua.c` adds three things to the library:

1. **A bounded allocator.** `clua_alloc` replaces the allocator of Lua. It
   keeps the number of bytes the state has allocated and refuses an
   allocation that would grow the state past the cap of the caller. The
   refusal is a `NULL` return, so Lua raises a memory error.
2. **A deadline.** `clua_hook` is the count hook of the state. It checks
   the deadline of the run every 10000 VM instructions and raises a Lua
   error when the deadline has passed, so an endless loop aborts with a
   message.
3. **Run helpers.** `clua_run_file`, `clua_run_string`,
   `clua_set_global_string`, `clua_global_string`, `clua_memory_used` and
   `clua_timed_out` wrap the C API of Lua for the Swift side.

The sandbox rules (the removed globals, the empty `package.cpath`, the
read-only `io.open`, the soft `require`) are **not** in this file. They
live in the Lua bootstrap of the app,
`Sources/SketchyBarStudio/Support/LuaConfigRunner.swift`, because they are
easier to read and to change there.
