#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Watti"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
SDKROOT="$(xcrun --show-sdk-path)"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR"

clang \
  -fobjc-arc \
  -mmacosx-version-min=13.0 \
  -isysroot "$SDKROOT" \
  -framework Cocoa \
  -framework IOKit \
  -framework QuartzCore \
  "$ROOT_DIR/Sources/Watti/main.m" \
  -o "$BIN_DIR/$APP_NAME"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Built $APP_DIR"
