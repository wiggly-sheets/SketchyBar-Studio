#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SketchyBarStudio"
BUNDLE_ID="app.codex.SketchyBarStudio"
MIN_SYSTEM_VERSION="14.0"

# Liquid Glass lives in the macOS 26 SDK and later. The app still runs on
# macOS 14, but the build needs a recent SDK to compile the gated code.
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ ! "$SDK_MAJOR" =~ ^[0-9]+$ ]] || (( SDK_MAJOR < 26 )); then
  echo "SketchyBar Studio needs the macOS 26 SDK or later to build; found ${SDK_VERSION:-an unknown SDK}." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Assets/SketchyBarStudio.icns"

APP_VERSION="${SKETCHYBAR_STUDIO_VERSION:-}"
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
fi
APP_VERSION="${APP_VERSION:-0.0.0}"
APP_VERSION="${APP_VERSION#v}"
APP_BUILD="${SKETCHYBAR_STUDIO_BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"

# A version may carry a prerelease suffix, such as 1.0.0-test, because the
# release tooling stamps the version it was given.
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "invalid app version '$APP_VERSION' (expected X.Y.Z)" >&2
  exit 2
fi

if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "invalid app build '$APP_BUILD' (expected an integer)" >&2
  exit 2
fi

SWIFT_CONFIGURATION="debug"
UNIVERSAL_BUILD="false"

if [[ "$MODE" == "--universal-package" || "$MODE" == "universal-package" ]]; then
  SWIFT_CONFIGURATION="release"
  UNIVERSAL_BUILD="true"
fi

# Swift 6.4's SwiftPM records the deployment target in the sdk field of
# LC_BUILD_VERSION. macOS decides from that field whether an app gets the
# Liquid Glass design, so stamp the SDK the binary was really built with.
stamp_linker_sdk() {
  local binary="$1"
  local stamped="${binary}.sdk-stamped"
  /usr/bin/vtool -set-build-version macos "$MIN_SYSTEM_VERSION" "$SDK_VERSION" \
    -replace -output "$stamped" "$binary"
  mv "$stamped" "$binary"
  chmod +x "$binary"
}

build_bundle() {
  if [[ "$UNIVERSAL_BUILD" == "true" ]]; then
    swift build --configuration "$SWIFT_CONFIGURATION" --arch arm64 --arch x86_64
    BUILD_DIR="$(swift build --configuration "$SWIFT_CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
  else
    swift build --configuration "$SWIFT_CONFIGURATION"
    BUILD_DIR="$(swift build --configuration "$SWIFT_CONFIGURATION" --show-bin-path)"
  fi
  BUILD_BINARY="$BUILD_DIR/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  stamp_linker_sdk "$APP_BINARY"
  if [[ -f "$APP_ICON" ]]; then
    cp "$APP_ICON" "$APP_RESOURCES/SketchyBarStudio.icns"
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>SketchyBar Studio</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleIconFile</key>
  <string>SketchyBarStudio</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  # SwiftPM ad-hoc signs the standalone executable. Re-sign the completed
  # bundle so Info.plist and resources are sealed by one coherent identity.
  /usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
}

verify_bundle() {
  test -x "$APP_BINARY"
  test -f "$INFO_PLIST"
  test -f "$APP_RESOURCES/SketchyBarStudio.icns"
  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

  # The app must not opt out of the system design, and the linked SDK must
  # be the real one or macOS renders the pre-Liquid-Glass appearance.
  if /usr/bin/plutil -extract UIDesignRequiresCompatibility raw "$INFO_PLIST" >/dev/null 2>&1; then
    echo "Info.plist opts out of the current system design" >&2
    exit 1
  fi
  local stamped_sdks
  stamped_sdks="$(/usr/bin/vtool -show-build "$APP_BINARY" | awk '/^[[:space:]]*sdk / { print $2 }' | sort -u)"
  if [[ "$stamped_sdks" != "$SDK_VERSION" ]]; then
    echo "the bundle records SDK ${stamped_sdks:-unknown}, expected $SDK_VERSION" >&2
    exit 1
  fi

  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
}

open_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --package|package|--universal-package|universal-package)
    build_bundle
    verify_bundle
    echo "$APP_BUNDLE"
    ;;
  run)
    build_bundle
    open_app
    ;;
  --debug|debug)
    build_bundle
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    build_bundle
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--package|--universal-package|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
