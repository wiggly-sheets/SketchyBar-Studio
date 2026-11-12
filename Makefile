# SketchyBar Studio — build interface.
#
# `make` prints the list of targets. Every target is phony.

SHELL := /bin/bash

APP_NAME  := SketchyBarStudio
APP_TITLE := SketchyBar Studio
DIST_DIR  := dist
SPM_DIR   := .build
INSTALL_DIR ?= $(HOME)/Applications
INSTALL_APP := $(INSTALL_DIR)/$(APP_NAME).app

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

.PHONY: help build test verify run install app app-universal dmg-universal \
	release-artifacts release-notes release clean

.DEFAULT_GOAL := help

## help — list every target

help:
	@printf '%s\n' \
		'SketchyBar Studio — build targets.' \
		'' \
		'  help                   List every target (default).' \
		'  build                  Debug build of the SwiftPM package.' \
		'  test                   Run the changelog check and the SwiftPM test suite.' \
		'  verify                 Check architecture, version, icon and signature.' \
		'  run                    Install the bundle into ~/Applications and launch it.' \
		'  install                Copy the bundle into ~/Applications.' \
		'  app                    Build the universal bundle into dist/SketchyBarStudio.app.' \
		'  app-universal          Build the universal bundle into dist/SketchyBarStudio.app.' \
		'  dmg-universal          Build the universal disk image into dist/.' \
		'  release-artifacts      Build the disk image and its verified checksum sidecar.' \
		'  release-notes VERSION=x.y.z  Print the changelog section of a version.' \
		'  release VERSION=x.y.z  Bump the changelog, test, build, verify, commit and tag.' \
		'  clean                  Remove .build/ and dist/.' \
		'' \
		'Notes' \
		'  The version comes from the command line only, never from a file in the' \
		'  repository. `make release VERSION=1.0.3` moves [Unreleased] to 1.0.3,' \
		'  stamps it into the bundle, runs the tests, builds and verifies the' \
		'  artifacts, commits the bump and creates the tag. A published release takes' \
		'  its version from the tag, so the tag is the only source of truth.' \
		'  CHANGELOG.md follows the shared shape and `make test` checks it.' \
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
	cd "$(ROOT)" && ./scripts/changelog.sh check
	cd "$(ROOT)" && swift test

## verify — check the built bundle

verify:
	@bundle="$(ROOT)/$(DIST_DIR)/$(APP_NAME).app"; \
	test -d "$$bundle" || { \
		echo "error: $$bundle is missing. Run make app first."; \
		exit 1; \
	}; \
	test -x "$$bundle/Contents/MacOS/$(APP_NAME)" || { \
		echo "error: $$bundle has no executable."; \
		exit 1; \
	}; \
	test -f "$$bundle/Contents/Resources/$(APP_NAME).icns" || { \
		echo "error: $$bundle ships no $(APP_NAME).icns."; \
		exit 1; \
	}; \
	archs="$$(lipo -archs "$$bundle/Contents/MacOS/$(APP_NAME)" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)"; \
	echo "Architectures: $$archs"; \
	test "$$archs" = "arm64 x86_64" || { \
		echo "error: expected a universal binary, got [$$archs]."; \
		exit 1; \
	}; \
	if [ -n "$(strip $(VERSION))" ]; then \
		version="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$bundle/Contents/Info.plist")"; \
		echo "Bundle version: $$version (expected $(VERSION))"; \
		test "$$version" = "$(VERSION)" || { \
			echo "error: the bundle reports $$version, but $(VERSION) was expected."; \
			exit 1; \
		}; \
	else \
		echo "Bundle version: $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$bundle/Contents/Info.plist") (no VERSION given)"; \
	fi
	codesign --verify --deep --strict "$(ROOT)/$(DIST_DIR)/$(APP_NAME).app"
	@echo "Verified $(DIST_DIR)/$(APP_NAME).app."

## install — copy the bundle into ~/Applications

install: app
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_APP)"
	ditto "$(ROOT)/$(DIST_DIR)/$(APP_NAME).app" "$(INSTALL_APP)"
	@echo "Installed $(INSTALL_APP)"

## run — install the bundle and launch it

run: install
	open "$(INSTALL_APP)"

## app — the bundle the product ships

app: app-universal

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
	cd "$(ROOT)/$(DIST_DIR)" && shasum -a 256 -c "$(DMG_NAME).sha256"
	@cat "$(ROOT)/$(DIST_DIR)/$(DMG_NAME).sha256"

## release-notes — print the changelog section of a version

release-notes:
	@if [ -z "$(strip $(VERSION))" ]; then \
		echo "error: make release-notes needs a version, for example: make release-notes VERSION=1.0.3"; \
		exit 1; \
	fi
	@./scripts/changelog.sh notes "$(VERSION)"

## release — bump, test, build, verify, commit and tag, without pushing

release:
	@if [ -z "$(strip $(VERSION))" ]; then \
		echo "error: make release needs a version, for example: make release VERSION=1.0.3"; \
		exit 1; \
	fi
	@APP_NAME="$(APP_TITLE)" ./scripts/release.sh "$(VERSION)"

## clean — remove everything the build produces

clean:
	rm -rf "$(ROOT)/$(SPM_DIR)" "$(ROOT)/$(DIST_DIR)"
	@echo "Removed $(SPM_DIR)/ and $(DIST_DIR)/."
