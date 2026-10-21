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
# The sink file comes from the environment, set by the preview runner.
sink="$SKETCHYBAR_STUDIO_PREVIEW_SINK"

# -m and --message are the message marker. The client strips it before it
# sends the message (src/sketchybar.c:170-172), and the fork's own space item
# uses this form (src/bar_item.c:430). Skip it before the alias is read.
case "$1" in
  -m|--message)
    shift
    ;;
esac

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
* It accepts `--set`, `-m --set` and `--message --set`. The marker is skipped before the alias is read, so a script written `sketchybar -m --set clock label="12:00"` reaches the same path as `sketchybar --set clock label="12:00"`.

The vendored `fork_exec` must be patched to set the child environment (`PATH` with the shim directory first, plus the sink variable). That patch is a modification of the vendored code and must be declared, per GPLv3 §5.

Known limit: the shim intercepts a `sketchybar` that is resolved through `PATH`. A script that calls the binary by absolute path is not intercepted, and such a call reaches the real daemon and does change the live bar. The mitigations are:

* the child `PATH` is scrubbed so it does not contain the directory of the real binary, so a script that resolves `sketchybar` by name cannot reach the real one;
* the preview warns when a script references an absolute `sketchybar` path, so the user knows the script was not intercepted.

The acceptance criterion of this stage is therefore about the `PATH` case, not about an absolute path.

### What is intercepted and what is not

The scrub of the `PATH` only touches the `PATH` the child inherits. Three cases reach the daemon anyway, and the preview cannot see them:

| Case | What happens | What the preview does |
| --- | --- | --- |
| A script calls `sketchybar` and the child resolves it through the `PATH` | The shim is the first `sketchybar` of the `PATH`, so the call lands in the sink of the preview. | Nothing to report. |
| A script calls `/opt/homebrew/bin/sketchybar` | The call is not intercepted: it reaches the live bar. | The preview warns, because the text of the script names the binary with a path. |
| A script sets its own `PATH` (`PATH=/opt/homebrew/bin:$PATH sketchybar …`) | The script puts the real binary in front of the shim. The call can reach the live bar. | The preview warns, because the text of the script names the binary and sets the `PATH`. |
| A script calls a wrapper (`~/bin/sb`), and the wrapper calls the binary | The wrapper is not the shim, so the call can reach the live bar. | Nothing: the text of the script does not name the binary. This is a residual limit. |
| A script runs `env -i sketchybar …` | `env -i` drops the environment, so the child gets the default `PATH` of `env`, which the scrub did not touch. The call can reach the live bar. | Nothing: the text of the script does not name the binary. This is a residual limit. |

The preview does not claim that the live bar cannot be reached. It says what it cannot intercept.

## Files

**Create.** `Sources/SketchyBarStudio/Services/PreviewScriptShim.swift`, `Sources/SketchyBarStudio/Services/PreviewScriptRunner.swift`, `Tests/SketchyBarStudioTests/PreviewScriptShimTests.swift`, `Tests/SketchyBarStudioTests/PreviewIsolationTests.swift`.

**Modify.** `Sources/CSketchyBar/src/misc/helpers.h` (the `fork_exec` patch), `Sources/CSketchyBar/MODIFICATIONS.md`, `Sources/CSketchyBar/shim/sketchybar_preview_fork.c` if the patch is not fully contained in `helpers.h`. The "no writes to the user's config" safety case goes into the existing `Tests/SketchyBarStudioTests/FileSafetyTests.swift`.

**Do not touch.** `Sources/SketchyBarStudio/Views/**`, `Sources/SketchyBarStudio/Stores/**`, `dist/`, and any file under a user config root.

## How the scripts run

The scripts of the items run the way the daemon runs them, and the preview does not have a second rule for them.

The daemon runs the script of an item from its clock, with the routine of the item and nothing else (`src/bar_manager.c:554`): `bar_item_update(item, NULL, false, NULL)`. That call decides three things:

* whether the script runs at all: `updates = false` never runs it, an item without `update_freq` runs it only on an event, and `updates = when_shown` runs it only while the item is on a bar (`src/bar_item.c:127-139`);
* when the script runs: the counter of the item decides (`src/bar_item.c:132-133`), so an item with `update_freq = 60` runs its script every 60 seconds;
* what the child of the script sees: the environment of the item itself, with the name of the item, the variables of the item and the sender (`src/bar_item.c:142-161`).

The preview uses that call, so an item that the daemon would not update shows no live value in the preview either. **An item without `update_freq` shows no live value: that is the truth of the daemon, not a defect of the preview.**

The preview rebuilds its item tree on every render and on every tick of the timer, so the counter of an item and the fact that it was on a bar are kept between the trees (`shim/sketchybar_preview_state.c`). The cadence of the daemon therefore survives the rebuild.

There are two routes, and they keep their results apart (`Sources/SketchyBarStudio/Services/PreviewScriptRunner.swift`):

* the **render route** runs the scripts of the items through the vendored core, so the child gets the environment of the item itself. The timer uses this route, once per tick, and the render reuses the result;
* the **timer route** runs the scripts by their text, for a caller that has no tree of items. The child gets the name of the item and the sender only.

The result of the timer route never replaces the result of the render route. The two routes do not run the same scripts in the same environment, and the render shows the values of the render route.

The key of the values holds the scripts of the vendored core, not the scripts of the config: a space item gets the script of the daemon (`src/bar_item.c:428-431`), and the item is cached under its own script.

## The deviations of this stage

The stage has three deviations from its own acceptance criteria. They are deliberate, and they are listed here so that a later stage knows what it inherits.

### The timer does not stop with the pane

The acceptance criterion of the stage is "the timer stops when the preview pane is hidden". The stage does not touch `Sources/SketchyBarStudio/Views/**`, and the pane cannot tell the service that it is hidden.

The substitute is the idle timeout of the runner: the timer stops when no render was requested for ten seconds (`PreviewScriptRunner.idleTimeout`). The cost of the substitute: the timer keeps forking the scripts of the user for up to ten seconds after the pane is hidden, and any keystroke anywhere in the editor keeps it alive at one hertz.

`BarRendererService.stopLiveValues()` stops the timer on demand. A stage that may change the views calls it when the pane is hidden.

The timer cannot outlive the preview harmfully: `sb_preview_run_script` takes no handle and never touches the model of the preview, and the two routes serialise on the lock of the runner.

### The sink escapes the newlines

The sink holds one line per property, so a value that holds a newline breaks the line. The shim escapes the backslashes and the newlines, and the preview unescapes them again (`PreviewScriptShim.unescaped`). The transport of SketchyBar is NUL separated and keeps such a value whole (`src/misc/helpers.h:247-263`), so the preview keeps it and the sink does not. That is the deviation from the tab separated contract of the stage.

### The residual limits of the isolation

The table above lists the cases the preview cannot intercept: a script that sets its own `PATH`, a wrapper script and `env -i`. The preview warns about the first one and says nothing about the other two.

## Acceptance criteria

* A script that does `sketchybar --set clock label="12:00"` changes the label in the preview.
* A script that does `sketchybar -m --set clock label="12:00"` changes the label in the preview, the same way the plain `--set` form does.
* A script that resolves `sketchybar` through `PATH` cannot change the live bar. Checkable with `sketchybar --query clock` before and after: the value is unchanged. These tests need a running daemon; they are skipped when `sketchybar --query bar` fails.
* A script that sleeps for longer than the timeout is killed, and the preview reports the timeout.
* A script that calls `sketchybar --something-unsupported` produces a warning and no change to the live bar.
* The timer stops when the preview pane is hidden. **Deviation:** the pane cannot tell the service that it is hidden without a change in the views, so the timer stops after ten idle seconds instead. See "The deviations of this stage".
* The shim never invokes the real `sketchybar` binary: the child process path resolves to the shim, and the shim exits with 64 for any command it does not handle.
* The child `PATH` does not contain the directory of the real `sketchybar` binary.
* The preview warns when a script references an absolute `sketchybar` path.
* The shim script and its sink file are removed after the render, and the sink file is not written outside the per-render temporary directory.

## Tests

`PreviewScriptShimTests.swift` (unit tests for argument parsing and the sink format, including a test for the `-m --set` form) and `PreviewIsolationTests.swift` (the "no live-bar mutation without consent" test). The shared strategy is in [testing.md](testing.md).

A soak test runs the live-value loop — create a preview, run the item scripts, read the sink, re-render, destroy — a few hundred times, and asserts that the file-descriptor count and the resident memory do not grow. It is the live-value counterpart of the Stage 2 soak test. The loop runs both routes of the runner, inside an autorelease pool, so the numbers mean something: the pool and the routes are the path of the app.

The tests of the scripts of the items:

| Test | What it holds |
| --- | --- |
| `testTheScriptOfAnItemSetsItsLabelInThePreview` | The script of an item sets its label in the preview. |
| `testAnItemThatDoesNotUpdateNeverRunsItsScript` | The gate of the daemon: `updates = false` never runs the script. |
| `testAnItemWithoutAnUpdateFrequencyShowsNoLiveValue` | The truth of the daemon: an item without `update_freq` shows no live value. |
| `testTheTwoRoutesDoNotRunTheScriptsInTheSameEnvironment` | The render route gives the child the variables of the item, the timer route does not, and the timer never replaces the result of the render. |
| `testTheBatchOfScriptsHasOneDeadline` | A batch of scripts that hang costs one timeout and not one per script. |
| `testAScriptThatSetsItsOwnPathIsAWarning` | A script that sets its own `PATH` is a warning. |
| `testAMentionInACommentIsNoWarning` | A mention inside a comment is not a warning. |
| `testTheChildOfAScriptHasNoDirectoryWithABinaryOnItsPath` | The child of a script has no directory with a binary on its `PATH`. The test builds that directory, so the assertion always means something. |
| `testTheScriptsOfThePreviewCannotChangeTheLiveBar` | The live bar of the user is untouched. It needs a running daemon and is skipped when there is none, so the claim of the isolation is **unproven on a machine without the daemon**. |

## Risks and unknowns

* A preview script reaches the live bar. The user's real bar changes without consent. Mitigation: the PATH shim, the patched child environment, the "no live-bar mutation" test, and the rule that the shim never forwards an unknown command. A script that calls the binary by absolute path is a known limit and is stated.
* Open question 1: whether a value with a space survives the per-property parse is **UNVERIFIED**. The transport and the `=` split preserve spaces (`src/sketchybar.c:60-108`, `src/misc/helpers.h:260-276`, `src/message.c:468-478`); confirm `bar_item_parse_set_message` and the text parser by experiment before this stage and [Stage 7](phase-7-live-update-mode.md) rely on it.
* Open question 7: how long does a typical item script take, and what timeout is right? The value is a project decision, informed by measurement.
* The shim script reads the sink path from `$SKETCHYBAR_STUDIO_PREVIEW_SINK`. The environment variable is the mechanism; the script above already says so in its header comment.

## Done when

A script's `--set` call changes the preview and leaves the live bar untouched, an unsupported command produces a warning, the timeout kills a long script, the timer stops with the pane, the isolation tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
