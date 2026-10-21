# Vendored upstream

## Lua 5.5.0

* **Version:** Lua 5.5.0, released 15 December 2025.
* **Upstream:** <https://www.lua.org/> — <https://www.lua.org/ftp/lua-5.5.0.tar.gz>
* **Licence:** MIT. The verbatim text is in `LICENSE`. It was taken from the
  copyright notice at the end of the upstream header `src/lua.h`
  (`Copyright (C) 1994-2025 Lua.org, PUC-Rio.`). The same notice with the
  year 2026 is in the header of the Homebrew build of Lua 5.5.1,
  `/opt/homebrew/Cellar/lua/5.5.1/include/lua/lua.h`.
* **Where the sources came from:** the copy in the local SbarLua checkout,
  `lua-5.5.0/src`, which is the upstream release without a patch.

## What is vendored

`lua/` holds the sources of the library: every `.c` and every `.h` of the
upstream `src` directory, with two exceptions.

* `lua.c` is not vendored: it is the standalone interpreter, and the app
  needs the library, not a program.
* `luac.c` is not vendored: it is the standalone compiler, and the app has
  no use for it.

The prebuilt `src/lua` and `src/luac` binaries are not vendored either.

## The files of this target that are not upstream

| File | What it is |
| --- | --- |
| `clua.c` | The wrapper: the bounded allocator, the deadline hook, the run helpers. |
| `include/clua.h` | The public C API of the wrapper. |

The sources in `lua/` are byte-identical to the upstream release. The
changes of this project are listed in `MODIFICATIONS.md`.
