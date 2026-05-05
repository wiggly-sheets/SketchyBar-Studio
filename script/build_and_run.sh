#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SketchyBarStudio"
BUNDLE_ID="app.codex.SketchyBarStudio"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Assets/SketchyBarStudio.icns"

SWIFT_CONFIGURATION="debug"
UNIVERSAL_BUILD="false"

if [[ "$MODE" == "--universal-package" || "$MODE" == "universal-package" ]]; then
  SWIFT_CONFIGURATION="release"
  UNIVERSAL_BUILD="true"
fi

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
}

verify_bundle() {
  test -x "$APP_BINARY"
  test -f "$INFO_PLIST"
  test -f "$APP_RESOURCES/SketchyBarStudio.icns"
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
