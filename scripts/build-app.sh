#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AiGallery"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
VERSION="${VERSION:-${version:-}}"
OUTPUT_NAME="$APP_NAME"
if [[ -n "$VERSION" ]]; then
  OUTPUT_NAME="$APP_NAME-$VERSION"
fi
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$OUTPUT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_TEMPLATE="$ROOT_DIR/packaging/Info.plist"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/packaging/AppIcon.png"
APP_ICON_NAME="AppIcon"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
SWIFTPM_CACHE_DIR="$ROOT_DIR/.build/swiftpm-cache"

mkdir -p "$MODULE_CACHE_DIR" "$SWIFTPM_CACHE_DIR"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
export SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR"

build_icns() {
  local iconset_dir="$DIST_DIR/$APP_ICON_NAME.iconset"
  local output_icns="$RESOURCES_DIR/$APP_ICON_NAME.icns"

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$APP_ICON_SOURCE" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$APP_ICON_SOURCE" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil -c icns "$iconset_dir" -o "$output_icns"
  rm -rf "$iconset_dir"
}

echo "Building $APP_NAME ($BUILD_CONFIG)..."
swift build -c "$BUILD_CONFIG" --package-path "$ROOT_DIR" --product "$APP_NAME"

BIN_DIR="$(swift build -c "$BUILD_CONFIG" --package-path "$ROOT_DIR" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Expected built executable at $BIN_PATH but it was not found." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$PLIST_TEMPLATE" "$PLIST_PATH"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST_PATH"
fi

if [[ -f "$APP_ICON_SOURCE" ]]; then
  build_icns
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo
echo "Created app bundle:"
echo "  $APP_DIR"
if [[ -n "$VERSION" ]]; then
  echo "Version:"
  echo "  $VERSION"
fi
echo
echo "You can open it with:"
echo "  open \"$APP_DIR\""
