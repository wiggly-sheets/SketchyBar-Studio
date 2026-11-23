# SketchyBar Studio — build interface.
#
# `make` prints the list of targets. Every target is phony.

SHELL := /bin/bash

APP_NAME  := SketchyBarStudio
APP_TITLE := SketchyBar Studio
DIST_DIR    := dist
RELEASE_DIR := release
SPM_DIR     := .build
INSTALL_DIR ?= $(HOME)/Applications
INSTALL_APP := $(INSTALL_DIR)/$(APP_NAME).app

# One bundle per architecture, each in its own folder, so neither build
# overwrites the other.
BUNDLE_ARM   := $(DIST_DIR)/arm64/$(APP_NAME).app
BUNDLE_INTEL := $(DIST_DIR)/x86_64/$(APP_NAME).app
BUNDLE_UNIVERSAL := $(DIST_DIR)/$(APP_NAME).app

# install and run take the bundle of the machine they run on.
HOST_TARGET := $(if $(filter arm64,$(shell uname -m)),app-arm,app-intel)
HOST_BUNDLE := $(if $(filter arm64,$(shell uname -m)),$(BUNDLE_ARM),$(BUNDLE_INTEL))

# Root of the repository, so every target works from any directory.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# The version comes from the command line: `make release VERSION=1.0.3`.
VERSION ?=

# The targets that name a file need the version on the command line.
VERSION_TARGETS := dmg dmg-arm dmg-intel dmg-universal release-artifacts release

ifneq ($(strip $(VERSION)),)
VERSION_OK := $(shell printf '%s' '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$$' && echo yes)
ifneq ($(VERSION_OK),yes)
$(error the version "$(VERSION)" is not X.Y.Z, for example: make release VERSION=1.0.3)
endif
DMG_ARM   := $(RELEASE_DIR)/$(APP_NAME)-$(VERSION)-arm64.dmg
DMG_INTEL := $(RELEASE_DIR)/$(APP_NAME)-$(VERSION)-x86_64.dmg
DMG_UNIVERSAL := $(RELEASE_DIR)/$(APP_NAME)-$(VERSION)-universal.dmg
CHECKSUMS := $(RELEASE_DIR)/checksums.txt
else ifneq ($(filter $(VERSION_TARGETS),$(MAKECMDGOALS)),)
$(error $(firstword $(MAKECMDGOALS)) needs a version, for example: make $(firstword $(MAKECMDGOALS)) VERSION=1.0.3)
endif

.PHONY: help build test verify run install app app-arm app-intel app-universal \
	dmg dmg-arm dmg-intel dmg-universal release-artifacts release-notes release \
	clean

.DEFAULT_GOAL := help

## help — list every target

help:
	@printf '%s\n' \
		'SketchyBar Studio — build targets.' \
		'' \
		'  help                   List every target (default).' \
		'  build                  Debug build of the SwiftPM package.' \
		'  test                   Run the changelog check and the SwiftPM test suite.' \
		'  verify                 Check both architectures, version, icon and signature.' \
		'  run                    Install the bundle into ~/Applications and launch it.' \
		'  install                Copy the bundle into ~/Applications.' \
		'  app                    Build the Apple silicon and the Intel bundle.' \
		'  app-arm                Build the Apple silicon bundle into dist/arm64/.' \
		'  app-intel              Build the Intel bundle into dist/x86_64/.' \
		'  app-universal          Build the universal bundle into dist/.' \
		'  dmg                    Build the Apple silicon and the Intel disk image.' \
		'  dmg-arm                Build the Apple silicon disk image.' \
		'  dmg-intel              Build the Intel disk image.' \
		'  dmg-universal          Build the universal disk image into release/.' \
		'  release-artifacts      Build both disk images and their verified checksums.' \
		'  release-notes VERSION=x.y.z  Print the changelog section of a version.' \
		'  release VERSION=x.y.z  Bump the changelog, test, build, verify, commit and tag.' \
		'  clean                  Remove .build/, dist/ and release/.' \
		'' \
		'Notes' \
		'  The version comes from the command line only, never from a file in the' \
		'  repository. `make release VERSION=1.0.3` moves [Unreleased] to 1.0.3,' \
		'  stamps it into the bundle, runs the tests, builds and verifies the' \
		'  artifacts, commits the bump and creates the tag. A published release takes' \
		'  its version from the tag, so the tag is the only source of truth.' \
		'  CHANGELOG.md follows the shared shape and `make test` checks it.' \
		'  The release publishes release/SketchyBarStudio-<version>-arm64.dmg,' \
		'  release/SketchyBarStudio-<version>-x86_64.dmg and release/checksums.txt.' \
		'  The checksum file holds one line per disk image: the digest, two spaces and' \
		'  the bare file name.' \
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
	@for spec in "arm64:$(BUNDLE_ARM)" "x86_64:$(BUNDLE_INTEL)"; do \
		want="$${spec%%:*}"; \
		bundle="$(ROOT)/$${spec#*:}"; \
		binary="$$bundle/Contents/MacOS/$(APP_NAME)"; \
		test -d "$$bundle" || { \
			echo "error: $$bundle is missing. Run make app first."; \
			exit 1; \
		}; \
		test -x "$$binary" || { \
			echo "error: $$bundle has no executable."; \
			exit 1; \
		}; \
		test -f "$$bundle/Contents/Resources/$(APP_NAME).icns" || { \
			echo "error: $$bundle ships no $(APP_NAME).icns."; \
			exit 1; \
		}; \
		archs="$$(lipo -archs "$$binary" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)"; \
		echo "$$bundle architectures: $$archs"; \
		test "$$archs" = "$$want" || { \
			echo "error: expected $$want in $$bundle, got [$$archs]."; \
			exit 1; \
		}; \
		if [ -n "$(strip $(VERSION))" ]; then \
			version="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$bundle/Contents/Info.plist")"; \
			echo "$$bundle version: $$version (expected $(VERSION))"; \
			test "$$version" = "$(VERSION)" || { \
				echo "error: the bundle reports $$version, but $(VERSION) was expected."; \
				exit 1; \
			}; \
		else \
			echo "$$bundle version: $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$bundle/Contents/Info.plist") (no VERSION given)"; \
		fi; \
		codesign --verify --deep --strict "$$bundle" || exit 1; \
	done
	@echo "Verified $(BUNDLE_ARM) and $(BUNDLE_INTEL)."

## install — copy the bundle into ~/Applications

install: $(HOST_TARGET)
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_APP)"
	ditto "$(ROOT)/$(HOST_BUNDLE)" "$(INSTALL_APP)"
	@echo "Installed $(INSTALL_APP)"

## run — install the bundle and launch it

run: install
	open "$(INSTALL_APP)"

## app — both per-architecture bundles

app: app-arm app-intel

## app-arm — the Apple silicon bundle

app-arm:
	cd "$(ROOT)" && SKETCHYBAR_STUDIO_VERSION="$(VERSION)" bash ./script/build_and_run.sh --arm-package

## app-intel — the Intel bundle

app-intel:
	cd "$(ROOT)" && SKETCHYBAR_STUDIO_VERSION="$(VERSION)" bash ./script/build_and_run.sh --intel-package

## app-universal — the one universal bundle

app-universal:
	cd "$(ROOT)" && SKETCHYBAR_STUDIO_VERSION="$(VERSION)" bash ./script/build_and_run.sh --universal-package

## dmg — both per-architecture disk images

dmg: dmg-arm dmg-intel

## dmg-arm — the Apple silicon disk image

dmg-arm: app-arm
	@mkdir -p "$(ROOT)/$(RELEASE_DIR)"
	cd "$(ROOT)" && npx --yes create-dmg@8.1.0 --overwrite --no-code-sign \
		--no-version-in-filename --dmg-title="$(APP_TITLE)" \
		"$(BUNDLE_ARM)" "$(DIST_DIR)/arm64"
	mv "$(ROOT)/$(DIST_DIR)/arm64/$(APP_TITLE).dmg" "$(ROOT)/$(DMG_ARM)"
	@echo "Built $(DMG_ARM)"

## dmg-intel — the Intel disk image

dmg-intel: app-intel
	@mkdir -p "$(ROOT)/$(RELEASE_DIR)"
	cd "$(ROOT)" && npx --yes create-dmg@8.1.0 --overwrite --no-code-sign \
		--no-version-in-filename --dmg-title="$(APP_TITLE)" \
		"$(BUNDLE_INTEL)" "$(DIST_DIR)/x86_64"
	mv "$(ROOT)/$(DIST_DIR)/x86_64/$(APP_TITLE).dmg" "$(ROOT)/$(DMG_INTEL)"
	@echo "Built $(DMG_INTEL)"

## dmg-universal — the universal disk image

dmg-universal: app-universal
	@mkdir -p "$(ROOT)/$(RELEASE_DIR)"
	cd "$(ROOT)" && npx --yes create-dmg@8.1.0 --overwrite --no-code-sign \
		--no-version-in-filename --dmg-title="$(APP_TITLE)" \
		"$(BUNDLE_UNIVERSAL)" "$(DIST_DIR)"
	mv "$(ROOT)/$(DIST_DIR)/$(APP_TITLE).dmg" "$(ROOT)/$(DMG_UNIVERSAL)"
	@echo "Built $(DMG_UNIVERSAL)"

## release-artifacts — both disk images and the checksums a tap can verify

release-artifacts: dmg
	cd "$(ROOT)/$(RELEASE_DIR)" && shasum -a 256 "$(notdir $(DMG_ARM))" "$(notdir $(DMG_INTEL))" > "$(notdir $(CHECKSUMS))"
	cd "$(ROOT)/$(RELEASE_DIR)" && shasum -a 256 -c "$(notdir $(CHECKSUMS))"
	@cat "$(ROOT)/$(CHECKSUMS)"

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
	rm -rf "$(ROOT)/$(SPM_DIR)" "$(ROOT)/$(DIST_DIR)" "$(ROOT)/$(RELEASE_DIR)"
	@echo "Removed $(SPM_DIR)/, $(DIST_DIR)/ and $(RELEASE_DIR)/."
