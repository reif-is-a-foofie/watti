#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/Watti.app"
OUT_DIR="$ROOT_DIR/build"
DMG_PATH="$OUT_DIR/Watti.dmg"
VOL_NAME="Watti"
STAGE_DIR="$OUT_DIR/dmg-stage"
BACKGROUND_SRC="$ROOT_DIR/Assets/dmg-open-anyway.png"
PRIVACY_WEBLOC_NAME="Open Privacy & Security.webloc"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing $APP_PATH (run ./build.sh first)" >&2
  exit 1
fi

if [[ ! -f "$BACKGROUND_SRC" ]]; then
  echo "Missing $BACKGROUND_SRC (needed for DMG background)" >&2
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Finder DMG background image (hidden folder)
mkdir -p "$STAGE_DIR/.background"
cp "$BACKGROUND_SRC" "$STAGE_DIR/.background/background.png"

# Clickable deep-link into System Settings → Privacy & Security.
cat >"$STAGE_DIR/$PRIVACY_WEBLOC_NAME" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>URL</key>
  <string>x-apple.systempreferences:com.apple.preference.security?Privacy</string>
</dict>
</plist>
EOF

rm -f "$DMG_PATH"

TMP_RW_DMG="$OUT_DIR/Watti-rw.dmg"
rm -f "$TMP_RW_DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -ov -format UDRW "$TMP_RW_DMG" >/dev/null

MOUNT_POINT="$(
  hdiutil attach -nobrowse -readwrite "$TMP_RW_DMG" \
  | python3 -c 'import re,sys; t=sys.stdin.read(); m=re.findall(r"(/Volumes/.*)$", t, flags=re.M); print(m[-1].strip() if m else "")'
)"

if [[ -z "$MOUNT_POINT" ]]; then
  echo "Failed to mount DMG" >&2
  exit 1
fi

osascript <<OSA >/dev/null
tell application "Finder"
  tell disk "${VOL_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 200, 900, 650}

    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128

    set background picture of theViewOptions to (POSIX file "${MOUNT_POINT}/.background/background.png") as alias
    delay 0.5

    try
      set position of file "Watti.app" of container window to {160, 240}
    end try
    try
      set position of item "Applications" of container window to {560, 240}
    end try
    if exists file "${PRIVACY_WEBLOC_NAME}" of container window then
      try
        set position of file "${PRIVACY_WEBLOC_NAME}" of container window to {360, 430}
      end try
    end if
    update without registering applications
  end tell
end tell
OSA

hdiutil detach "$MOUNT_POINT" >/dev/null || true

rm -f "$DMG_PATH"
hdiutil convert "$TMP_RW_DMG" -format UDZO -ov -o "$DMG_PATH" >/dev/null
rm -f "$TMP_RW_DMG"

echo "Built $DMG_PATH"
