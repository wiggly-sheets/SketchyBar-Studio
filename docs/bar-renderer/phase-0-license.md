# Stage 0 — Switch the project to GPL-3.0

## Goal

The repository carries GPL-3.0 before any GPL code lands in it. The vendored SketchyBar subset is GPL-3.0, so the app that links it must be GPL-3.0 as well. This stage changes only the licence, the notices and the documentation that states the licence.

## Depends on

None. This is the first stage.

## In scope / Out of scope

**In scope.** The `LICENSE` text, the `NOTICE` file, the licence lines of `README.md`, the `CHANGELOG.md` entry, and `CONTRIBUTING.md` if it states the licence.

**Out of scope.** Any code change, any vendored file, and the release notes for the GPL source offer (that belongs to [Stage 9](phase-9-docs-and-release.md)).

## Tasks

1. Replace `LICENSE` with the GPL-3.0 text.
2. Update the licence badge in `README.md:16` and the licence line in `README.md:219`.
3. Add a `NOTICE` file naming upstream FelixKratz and the wiggly-sheets fork, stating that the vendored code is modified, and pointing at the source offer.
4. Add a `CHANGELOG.md` entry under `## [Unreleased]`.
5. Update `CONTRIBUTING.md` if it states the licence.

### What GPLv3 requires of this repository

* **Ship the full corresponding source** (§6). The vendored SketchyBar source must be in the repository, and the release must offer the complete source of the distributed binary, including the Swift app.
* **Keep the licence and copyright notices** (§5). The upstream `LICENSE.md` and the copyright notices of every vendored file stay with the vendored files.
* **State that the code was modified** (§5). The patches this project makes (the headless shim, the window-record replacement, the `fork_exec` environment patch) must be declared, in the vendored tree and in the app's notices.
* **Installation Information for User Products** (§6.d). The app ships a macOS binary and the ability to run a modified version, so the release notes must tell the user how to get the source and how to build a modified version.

### What must be attributed

* **Both upstream FelixKratz and the wiggly-sheets fork.** The vendored code is the fork, and the fork descends from upstream. The notices name both.
* The app's own copyright stays with the owner.

### What must not be vendored

* **SbarLua.** Its licence could not be determined. The app parses SbarLua config itself and never links or ships SbarLua code.

### Trademark note

GPLv3 §7(e) carves trademarks out of the licence (`LICENSE.md:379-380`). "SketchyBar" is a product name of its authors. Using the name descriptively — to name the file format, the config directory, the CLI and the daemon the app talks to — is fine. Using it as the app's own product name, or as a brand for this app, is a separate trademark question and is out of scope for this plan.

## Files

**Create.** `NOTICE`.

**Modify.** `LICENSE`, `README.md` (lines 16 and 219), `CHANGELOG.md`, `CONTRIBUTING.md` (only if it states the licence).

**Do not touch.** `Package.swift`, everything under `Sources/`, everything under `Tests/`, `script/`, `dist/`, and any file under a user config root.

## Acceptance criteria

* `LICENSE` contains the GPL-3.0 text and `README.md:16` no longer says MIT.
* `NOTICE` names both upstream projects and the modifications.
* `README.md:219` states GPL-3.0 instead of MIT.
* `swift build` and `swift test` pass.
* No file under `Sources/` or `Tests/` changed in this stage.

## Tests

None needed; this stage changes no code. `swift build` and `swift test` still have to pass, because the master branch must stay green after every merge.

## Risks and unknowns

* The app is MIT today and the vendored code is GPL-3.0. The app cannot ship as MIT. This stage is the mitigation: the licence switches before any GPL code lands. The decision is already taken by the owner (D5).
* `CONTRIBUTING.md` may state the licence in a place other than the obvious one. Grep the whole repository for "MIT" and for "licence" before merging.

## Done when

`LICENSE` is the GPL-3.0 text, `NOTICE` names both upstream projects and the modifications, `README.md` states GPL-3.0 in both places, `CHANGELOG.md` has an `## [Unreleased]` entry, and `swift build` and `swift test` pass. The branch is merged into master with `git merge --no-ff`.
