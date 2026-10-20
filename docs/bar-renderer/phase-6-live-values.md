# Stage 6 — Live values in the preview

## Goal

The preview shows the values the item scripts produce. The scripts run inside the preview, and the `sketchybar --set` calls they make are captured by a shim, so a preview can never touch the user's live bar.

## Depends on

[Stage 5](phase-5-preview-pane.md) must be merged. The scripts run while the preview pane is visible.

## In scope / Out of scope

**In scope.** The script shim, the patched child environment, the script runner, the timeout, the warnings, and the timer.

**Out of scope.** Pushing to the live bar ([Stage 7](phase-7-live-update-mode.md)), and the exactness work ([Stage 8](phase-8-exactness-and-diff.md)).

## Tasks

1. Write `PreviewScriptShim`: generate the `sh` script into a per-render temporary directory, make it executable, and delete it afterwards.
2. Patch the vendored `fork_exec` so the child environment has the shim directory first on `PATH` and the sink variable set.
3. Write `PreviewScriptRunner`: run the item scripts on a timer while the preview pane is visible, read the sink file, and turn the captured `--set` calls into property assignments.
4. Enforce a timeout per script and kill the child when it overruns. Reuse the pattern of `SketchyBarStore.runSketchyBarReload` (`Stores/SketchyBarStore.swift:1806-1829`), which already runs a process with a timeout.
5. Surface every call the shim could not handle as a warning in the preview.
6. Stop the timer when the preview pane is not visible.

### The script shim

Item scripts run through `fork_exec` (`src/bar_item.c:166-168` → `src/misc/helpers.h:454-462` → `execvp("/usr/bin/env", {"env","sh","-c", command, NULL})`). A script normally does `sketchybar --set <alias> label="…"`, which would hit the user's live bar. The preview must never be able to touch the live bar.

The shim is a small `sh` script written into a per-render temporary directory, placed first on `PATH` for the script child process. It captures `--set` calls and writes them to a sink file instead of sending them to the Mach service.

```sh
#!/bin/sh
# $1 = sink file, set by the preview runner through the environment.
sink="$SKETCHYBAR_STUDIO_PREVIEW_SINK"
case "$1" in
  --set)
    # Remaining arguments are <alias> <prop>=<value> ...
    shift
    alias="$1"; shift
    for pair in "$@"; do
      printf '%s\t%s\n' "$alias" "$pair" >> "$sink"
    done
    exit 0
    ;;
  *)
    # Not handled. Report it, never forward it to the real binary.
    printf 'sketchybar: unsupported preview command: %s\n' "$*" >&2
    exit 64
    ;;
esac
```

Rules the shim must obey:

* It never executes or forwards to the real `sketchybar` binary.
* A command it does not handle is reported on stderr, surfaced in the preview as a warning, and never sent onward.
* The sink path comes from the environment, and the environment is set for the script child only.

The vendored `fork_exec` must be patched to set the child environment (`PATH` with the shim directory first, plus the sink variable). That patch is a modification of the vendored code and must be declared, per GPLv3 §5.

Known limit: the shim intercepts a `sketchybar` that is resolved through `PATH`. A script that calls the binary by absolute path is not intercepted. The acceptance criteria of this stage include a test that proves the live bar is unchanged after a hostile script runs.

## Files

**Create.** `Sources/SketchyBarStudio/Services/PreviewScriptShim.swift`, `Sources/SketchyBarStudio/Services/PreviewScriptRunner.swift`.

**Modify.** `Sources/CSketchyBar/src/misc/helpers.h` (the `fork_exec` patch), `Sources/CSketchyBar/MODIFICATIONS.md`, `Sources/CSketchyBar/shim/sketchybar_preview_fork.c` if the patch is not fully contained in `helpers.h`.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `dist/`, and any file under a user config root.

## Acceptance criteria

* A script that does `sketchybar --set clock label="12:00"` changes the label in the preview.
* The same script does **not** change the live bar. Checkable with `sketchybar --query clock` before and after: the value is unchanged.
* A script that sleeps for longer than the timeout is killed, and the preview reports the timeout.
* A script that calls `sketchybar --something-unsupported` produces a warning and no change to the live bar.
* The timer stops when the preview pane is hidden.
* The shim never invokes the real `sketchybar` binary: the child process path resolves to the shim, and the shim exits with 64 for any command it does not handle.
* The shim script and its sink file are removed after the render, and the sink file is not written outside the per-render temporary directory.

## Tests

`PreviewScriptShimTests.swift` (unit tests for argument parsing and the sink format) and `PreviewIsolationTests.swift` (the "no live-bar mutation without consent" test). The shared strategy is in [testing.md](testing.md).

## Risks and unknowns

* A preview script reaches the live bar. The user's real bar changes without consent. Mitigation: the PATH shim, the patched child environment, the "no live-bar mutation" test, and the rule that the shim never forwards an unknown command. A script that calls the binary by absolute path is a known limit and is stated.
* Open question 1: `--set` on the server re-splits a value on spaces, so a label with a space cannot be pushed. The transport preserves spaces (`src/sketchybar.c:60-108`, `src/misc/helpers.h:260-276`), so the risk is in the per-property parse. Confirm before this stage and [Stage 7](phase-7-live-update-mode.md) rely on it.
* Open question 7: how long does a typical item script take, and what timeout is right? The value is a project decision, informed by measurement.
* The comment at the top of the shim script says the sink file is `$1`, while the script reads it from `$SKETCHYBAR_STUDIO_PREVIEW_SINK`. The environment variable is the mechanism; correct the comment when the script is written.

## Done when

A script's `--set` call changes the preview and leaves the live bar untouched, an unsupported command produces a warning, the timeout kills a long script, the timer stops with the pane, the isolation tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
