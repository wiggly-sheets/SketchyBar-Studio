# Stage 9 — Documentation and release

## Goal

The docs describe what the app now does, and the release notes follow the project's style.

## Depends on

[Stage 8](phase-8-exactness-and-diff.md) must be merged. The feature claims have to be true before they are written down.

## In scope / Out of scope

**In scope.** `README.md`, `CHANGELOG.md`, `docs/RELEASE_CHECKLIST.md`, and the repo layout section of `AGENTS.md`.

**Out of scope.** Any code change, and the licence switch itself ([Stage 0](phase-0-license.md)).

## Tasks

1. Update the README feature list, the known limits, the licence section and the build-from-source section. The lines that need changing are in the README-lines table below.
2. Add the CHANGELOG entries, one per stage, under `## [Unreleased]`, using the existing `### Added` / `### Changed` / `### Fixed` sections and the existing one-sentence-per-change style.
3. Add the rows for the new checks to `docs/RELEASE_CHECKLIST.md`:
   * the preview renders a bar of a config that is not the live one;
   * the preview shows live values and the live bar is unchanged;
   * Restore puts the live bar back;
   * every README claim about the preview is checked against the shipped app;
   * `swift build`, `swift test` and `./script/build_and_run.sh --package` pass.
4. Note in the release notes that the binary contains GPL-3.0 code and that the corresponding source is available (§6.d).
5. Show the upstream commit that was vendored, in the About panel or in the release notes. The commit is recorded in `Sources/CSketchyBar/UPSTREAM.md`.
6. Add the new `Sources/CSketchyBar` target to the repo layout section of `AGENTS.md`.

### README lines that need updating

| Line | Current claim | What changes |
| --- | --- | --- |
| `README.md:16` | Licence badge says MIT | GPL-3.0 |
| `README.md:36` | Intro paragraph | May mention the in-app preview |
| `README.md:62` | "Includes an interactive draft bar preview" | Keep the reordering affordances, point at the new renderer |
| `README.md:63` | "Draws the bar preview with the real values of the config" | The current mock does not do this; rewrite for the new renderer and state the window-server limits |
| `README.md:88` | "optionally runs `sketchybar --reload`" | Mention the live-update mode and Restore |
| `README.md:110` | "ad-hoc signed, but not Developer ID signed" | Unchanged, but the licence of the shipped binary changes |
| `README.md:200-204` | "Known limits" | Add the renderer limits (alias, space, front app, media artwork, popups) |
| `README.md:219` | "MIT. See [LICENSE](LICENSE)." | GPL-3.0, plus the source offer (§6.d) |

## Files

**Create.** Nothing.

**Modify.** `README.md`, `CHANGELOG.md`, `docs/RELEASE_CHECKLIST.md`, `AGENTS.md`.

**Do not touch.** `Package.swift`, everything under `Sources/` and `Tests/`, `script/`, `dist/`, and any file under a user config root.

## Acceptance criteria

* Every README claim about the preview has a row in `docs/RELEASE_CHECKLIST.md`, and every one of those rows is checked against the shipped app before the release.
* The README states the licence and points at the source offer.
* The CHANGELOG has an entry for each stage.
* The release checklist has the new rows.
* The release notes state that the binary contains GPL-3.0 code and where the corresponding source is.
* The README's known-limits section names the renderer limits: no popups, no window-server content (`alias`, `space`, front-app icon, `media.artwork`), no interaction with the preview.
* `AGENTS.md` lists the `Sources/CSketchyBar` target in the repo layout.

## Tests

None; the checks are in the release checklist. The release checklist rows are run by hand before the release, and `swift build`, `swift test` and `./script/build_and_run.sh --package` have to pass on master.

## Risks and unknowns

* A README claim about the preview that the shipped app does not satisfy is a support problem. Every claim in the preview paragraph has to be checked against the running app before it is written.
* The source offer (§6.d) is a release obligation, not a documentation nicety. The release notes must say how to get the source and how to build a modified version.

## Done when

The README, the CHANGELOG, the release checklist and `AGENTS.md` describe the shipped behaviour, the GPL source offer is in the release notes, and the branch is merged into master with `git merge --no-ff` and master is green.
