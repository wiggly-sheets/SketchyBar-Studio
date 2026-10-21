# Stage 7 — The live-update mode and Restore

## Goal

The user can let Studio change the running SketchyBar, under their control, and can always put it back. Pushing to the live bar is a side effect on the user's running system, so it is opt-in, granular and reversible.

## Depends on

[Stage 5](phase-5-preview-pane.md) must be merged. [Stage 6](phase-6-live-values.md) is not required, but the live-update mode pushes the same property assignments the script shim captures, so read that stage first.

## In scope / Out of scope

**In scope.** The `LiveUpdateMode` setting, the live bar snapshot, the push path, the Restore action, and the safety rules below.

**Out of scope.** The renderer itself, the script shim ([Stage 6](phase-6-live-values.md)), and the release notes ([Stage 9](phase-9-docs-and-release.md)).

## Tasks

1. Add `LiveUpdateMode` to the models and a setting in `Views/SettingsView.swift`.
2. Write `Services/LiveBarService.swift`: take a snapshot of the live bar, push a set of property assignments to the running daemon, and restore the snapshot.
3. The snapshot holds the current property values of every item of the live bar, read with `sketchybar --query <item>`, and the bar level properties.
4. Wire `On Apply` into the existing apply path (`SketchyBarStore.applySketchyBarReload`, `Stores/SketchyBarStore.swift:899-905`).
5. Wire `While Editing` into the draft-change path, with a debounce.
6. Add the Restore button and its confirmation.

### The setting

```
Live bar update:
  Never          The live bar only changes when the user saves and applies the config.
  On Apply       The live bar updates when the user clicks Apply or Save & Apply.
  While Editing  The live bar updates as the user edits, debounced.
```

Plus an explicit **Restore** action that puts the live bar back.

### Safety rules, all of them mandatory

1. Nothing is pushed to the live bar without either an explicit user action (Apply, Save & Apply, Restore) or the `While Editing` setting being on. The default is `Never`.
2. `script` and `click_script` are never pushed. A draft's script belongs to the config, not to the running bar.
3. A snapshot of the live bar is taken before anything is pushed, and Restore puts it back.
4. Restore works even after the app restarts. The snapshot is written to disk.
5. A push that fails is reported, and the live bar is left as it was.
6. The mode is a setting, so the user can go back to `Never` at any time.

## Files

**Create.** `Sources/SketchyBarStudio/Services/LiveBarService.swift`.

**Modify.** `Sources/SketchyBarStudio/Models/BarRenderModels.swift`, `Sources/SketchyBarStudio/Views/SettingsView.swift`, `Sources/SketchyBarStudio/Stores/SketchyBarStore.swift`.

**Do not touch.** `Sources/CSketchyBar/**` (the vendored code does not push anything), `Sources/SketchyBarStudio/Views/DetailView.swift`, `dist/`, and any file under a user config root. The snapshot of the live bar is written under the app's own support directory, not under the user's config root.

## Acceptance criteria

* With the mode `Never`, editing a value does not change the live bar. Checkable with `sketchybar --query <item>`.
* With the mode `On Apply`, clicking Apply changes the live bar.
* With the mode `While Editing`, editing a value changes the live bar after the debounce interval.
* In every mode, Restore returns the live bar to the state it had before the first push.
* `script` and `click_script` are not pushed, in any mode.
* A push that fails leaves the live bar unchanged and reports the failure.
* The mode is `Never` on a fresh install.
* The snapshot survives an app restart: after a restart, Restore still returns the live bar to the snapshotted state.
* No push happens when the mode is `Never` and the user only edits, switches panes or previews a config.

## Tests

`PreviewIsolationTests.swift`: a test that the mode `Never` performs no `--set` call, and a test that the snapshot/restore round trip returns the original values. These tests need a running daemon; they are skipped when `sketchybar --query bar` fails. The shared strategy is in [testing.md](testing.md).

## Risks and unknowns

* Open question 1: whether a value with a space survives the per-property parse is **UNVERIFIED**. The transport and the `=` split preserve spaces (`src/sketchybar.c:60-108`, `src/misc/helpers.h:260-276`, `src/message.c:468-478`); confirm `bar_item_parse_set_message` and the text parser by experiment before this stage relies on it.
* A push that half succeeds leaves the live bar in a mixed state. Mitigation: rule 5, plus a snapshot taken before the first push, so Restore can put it back.
* The snapshot is written to disk and holds the user's live bar values. It must stay inside the app's own support directory, and it must not be written under the user's config root.

## Known limits

* An alias that the config declares twice is merged into one item by the config bridge, and the merged item keeps the last value of a property. The daemon refuses the second add and keeps the first item of the alias (`src/message.c:189-193`), so a push can set a value the running bar does not have, and the next reload of the config undoes it. The bridge owns the merge, and another branch owns the bridge, so this stage records the limit instead of changing it.
* The daemon writes the label and the icon raw (`src/text.c:1027`), so a quote in a value breaks the reply of a query. Such a reply is refused as a whole, because the reader would read the rest of it wrong. The item is then not pushed, and its value is never put back by a Restore.
* The daemon writes the settings of the bar flat, next to the keys of the bar itself (`src/bar_manager.c:1096-1119`, `src/background.c:261-297`), and the daemon wants the plain name of a property of the bar (`src/message.c:680-692`). The push reads and writes the bar that way, and the `bar.` prefix of the app never reaches the daemon.
* A name the daemon reads as a regular expression is never pushed and never put back: the daemon would set every item that matches it (`src/message.c:628-631`).

## Done when

The three modes behave as described, Restore returns the live bar to its state before the first push and works after a restart, `script` and `click_script` are never pushed, the isolation tests pass, and the branch is merged into master with `git merge --no-ff` and master is green.
