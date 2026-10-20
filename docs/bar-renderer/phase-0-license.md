# Stage 0 — Switch the project to GPL-3.0

**Status: done (2026-10-20).** The licence switch, the NOTICE and the README
changes are merged with this stage. The next stage is Stage 1.

## Goal

The repository carries GPL-3.0 before any GPL code lands in it. The vendored SketchyBar subset is GPL-3.0, so the app that links it must be GPL-3.0 as well. This stage changes only the licence, the notices and the documentation that states the licence.

## Depends on

None. This is the first stage.

## In scope / Out of scope

**In scope.** The `LICENSE` text, the `NOTICE` file, the licence lines of `README.md`, and the `CHANGELOG.md` entry. `CONTRIBUTING.md` is checked but changed only if it states the licence, which it does not today.

**Out of scope.** Any code change, any vendored file, and the release notes for the GPL source offer (that belongs to [Stage 9](phase-9-docs-and-release.md)).

## Tasks

1. Replace `LICENSE` with the GPL-3.0 text.
2. Update the licence badge in `README.md:16` and the licence line in `README.md:219`.
3. Add a `NOTICE` file naming upstream FelixKratz and the wiggly-sheets fork, stating that the vendored code is modified, and pointing at the source offer.
4. Add a `CHANGELOG.md` entry under `## [Unreleased]`.
5. Check `CONTRIBUTING.md`. It states no licence today, so it needs no change; if a licence statement appears there later, update it in the same stage.

### What GPLv3 requires of this repository

* **Ship the full corresponding source** (§6). The vendored SketchyBar source must be in the repository, and the release must offer the complete source of the distributed binary, including the Swift app.
* **Keep the licence and copyright notices** (§4(a) for verbatim copies, §6(a) for non-source forms). The upstream `LICENSE.md` and the copyright notices of every vendored file stay with the vendored files.
* **State that the code was modified** (§5, "Conveying Modified Source Versions", and specifically §5(b)). The patches this project makes (the headless shim, the window-record replacement, the `fork_exec` environment patch) must be declared, in the vendored tree and in the app's notices.
* **Installation Information for User Products** (§6.d). This duty bites only when the Corresponding Source is **not** distributed with the object code. Stage 0 requires the source to be distributed with the release, and the release notes carry a source pointer. If a binary ever ships without the source, the release notes must carry the installation information: how to get the source and how to build a modified version.

### What must be attributed

* **Both upstream FelixKratz and the wiggly-sheets fork.** The vendored code is the fork, and the fork descends from upstream. The notices name both.
* The app's own copyright stays with the owner.

### What must not be vendored

* **SbarLua.** Its licence could not be determined. The app parses SbarLua config itself and never links or ships SbarLua code.

### Trademark note

The GPL analysis is correct. GPLv3 §7(e) carves trademarks out of the licence (`LICENSE.md:379-380`), so using the name descriptively — to name the file format, the config directory, the CLI and the daemon the app talks to — is fine.

The app already carries "SketchyBar" in its own product name: it is called "SketchyBar Studio" (`README.md:5`), the repository is `wiggly-sheets/SketchyBar-Studio` (`README.md:15-16`), and the copyright line reads "Copyright (C) 2026 Wiggly-Sheets" (`LICENSE:2`). Whether that is a trademark question is a question for the owner, not a GPL question, and this plan does not change the product name. It is flagged here so the owner decides it explicitly rather than by accident.

**Decision (TAKEN 2026-10-20, by the owner).**

* GPLv3 §7(e) withholds trademark rights. The licence switch therefore settles the COPYING question only, not the NAME question.
* Using "SketchyBar" descriptively — to name the config format, the config directory, the CLI and the daemon the app talks to — is fine.
* Using it as the product name is the owner's call. The owner keeps the name "SketchyBar Studio" and adds the non-affiliation line to the README.
* The owner owns the wiggly-sheets fork that Stage 1 vendors from, so only upstream Felix Kratz's mark is not the owner's.
* No further trademark work is planned. Do not re-open this question.

## Files

**Create.** `NOTICE`.

**Modify.** `LICENSE`, `README.md` (lines 16 and 219), `CHANGELOG.md`. `CONTRIBUTING.md` is read but not modified unless it states the licence.

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

* The app was MIT when this stage was planned, and the vendored code is GPL-3.0. The app cannot ship as MIT. This stage was the mitigation: the licence switched before any GPL code landed. The decision is already taken by the owner (D5).
* `CONTRIBUTING.md` states no licence today, so the "update it if it states the licence" task is a no-op. Grep the whole repository for "MIT" and for "licence" before merging, in case another file states one.

## Done when

`LICENSE` is the GPL-3.0 text, `NOTICE` names both upstream projects and the modifications, `README.md` states GPL-3.0 in both places, `CHANGELOG.md` has an `## [Unreleased]` entry, and `swift build` and `swift test` pass. The branch is merged into master with `git merge --no-ff`.
