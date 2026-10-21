# SketchyBar Studio — build interface.
#
# `make` prints the list of targets. Every target is phony.

SHELL := /bin/bash

APP_NAME  := SketchyBarStudio
APP_TITLE := SketchyBar Studio
DIST_DIR  := dist
SPM_DIR   := .build

# Root of the repository, so every target works from any directory.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# The version comes from the command line: `make release VERSION=1.0.3`.
VERSION ?=

# The targets that name a file need the version on the command line.
VERSION_TARGETS := dmg-universal release-artifacts release

ifneq ($(strip $(VERSION)),)
VERSION_OK := $(shell printf '%s' '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$$' && echo yes)
ifneq ($(VERSION_OK),yes)
$(error the version "$(VERSION)" is not X.Y.Z, for example: make release VERSION=1.0.3)
endif
DMG_NAME := $(APP_NAME)-$(VERSION)-universal.dmg
else ifneq ($(filter $(VERSION_TARGETS),$(MAKECMDGOALS)),)
$(error $(firstword $(MAKECMDGOALS)) needs a version, for example: make $(firstword $(MAKECMDGOALS)) VERSION=1.0.3)
endif

.PHONY: help build test app-universal dmg-universal release-artifacts \
	release clean

.DEFAULT_GOAL := help

## help — list every target

help:
	@printf '%s\n' \
		'SketchyBar Studio — build targets.' \
		'' \
		'  help                   List every target (default).' \
		'  build                  Debug build of the SwiftPM package.' \
		'  test                   Run the SwiftPM test suite.' \
		'  app-universal          Build the universal bundle into dist/SketchyBarStudio.app.' \
		'  dmg-universal          Build the universal disk image into dist/.' \
		'  release-artifacts      Build the disk image and write its checksum sidecar.' \
		'  release VERSION=x.y.z  Build the artifacts, tag v<x.y.z> locally, print the push commands.' \
		'  clean                  Remove .build/ and dist/.' \
		'' \
		'Notes' \
		'  The version comes from the command line only, never from a file in the' \
		'  repository. `make release VERSION=1.0.3` stamps 1.0.3 into the bundle and' \
		'  names the disk image after it. A published release takes its version from' \
		'  the tag, so the tag is the only source of truth for a release.' \
		'  SketchyBar Studio ships one universal package, so there is no target per' \
		'  architecture.' \
		'  The release publishes dist/SketchyBarStudio-<version>-universal.dmg and the' \
		'  checksum sidecar next to it. The sidecar holds one line: the digest, two' \
		'  spaces and the bare file name.' \
		'  Signing stays ad-hoc, the identity is "-". There is no Developer ID' \
		'  identity and no notarization.' \
		'  The disk image needs create-dmg. The targets fetch the pinned version with' \
		'  `npx --yes create-dmg@8.1.0`, so Node has to be on the path.'

## build — debug build of the package

build:
	cd "$(ROOT)" && swift build

## test — test suite

test:
	cd "$(ROOT)" && swift test

## app-universal — the bundle the product ships

app-universal:
	cd "$(ROOT)" && SKETCHYBAR_STUDIO_VERSION="$(VERSION)" bash ./script/build_and_run.sh --universal-package

## dmg-universal — the disk image

dmg-universal: app-universal
	cd "$(ROOT)" && npx --yes create-dmg@8.1.0 --overwrite --no-code-sign \
		--no-version-in-filename --dmg-title="$(APP_TITLE)" \
		"$(DIST_DIR)/$(APP_NAME).app" "$(DIST_DIR)"
	mv "$(ROOT)/$(DIST_DIR)/$(APP_TITLE).dmg" "$(ROOT)/$(DIST_DIR)/$(DMG_NAME)"
	@echo "Built $(DIST_DIR)/$(DMG_NAME)"

## release-artifacts — the disk image and the sidecar the tap expects

release-artifacts: dmg-universal
	cd "$(ROOT)/$(DIST_DIR)" && shasum -a 256 "$(DMG_NAME)" > "$(DMG_NAME).sha256"
	@cat "$(ROOT)/$(DIST_DIR)/$(DMG_NAME).sha256"

## release — build the artifacts and tag them, without pushing

release:
	@if [ -n "$$(git -C "$(ROOT)" status --porcelain)" ]; then \
		echo "error: the working tree is dirty. Commit or stash your changes first."; \
		git -C "$(ROOT)" status --short; \
		exit 1; \
	fi
	@if git -C "$(ROOT)" rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null; then \
		echo "error: the tag v$(VERSION) already exists."; \
		exit 1; \
	fi
	$(MAKE) -C "$(ROOT)" release-artifacts VERSION=$(VERSION)
	git -C "$(ROOT)" tag -a "v$(VERSION)" -m "$(APP_TITLE) $(VERSION)"
	@echo ""
	@echo "Tagged v$(VERSION). The target pushed nothing. Push the branch and the tag with:"
	@echo "  git push origin master"
	@echo "  git push origin v$(VERSION)"

## clean — remove everything the build produces

clean:
	rm -rf "$(ROOT)/$(SPM_DIR)" "$(ROOT)/$(DIST_DIR)"
	@echo "Removed $(SPM_DIR)/ and $(DIST_DIR)/."
