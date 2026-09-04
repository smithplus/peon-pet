#!/bin/bash
# Builds PeonPet.app without an Xcode project: swiftc plus a hand-assembled bundle.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/PeonPet.app"
BIN="$APP/Contents/MacOS/PeonPet"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$(dirname "$BIN")" "$RES"

# Re-slice the atlas when the frames are missing, so a fresh clone can build.
# The atlas lives in the Electron app one level up; keep it out of git and slice
# it at build time so the frames are always derived, never duplicated.
ATLAS="$ROOT/../renderer/assets/orc-sprite-atlas.png"
[ -f "$ATLAS" ] || ATLAS="$HOME/projects/personal/peon-pet/renderer/assets/orc-sprite-atlas.png"
if [ ! -f "$ROOT/Resources/frames/f00.png" ] && [ -f "$ATLAS" ]; then
  echo "slicing atlas..."
  swift "$ROOT/Tools/slice.swift" "$ATLAS" "$ROOT/Resources/frames" 256
fi

swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  -o "$BIN" \
  "$ROOT"/Sources/*.swift

cp -R "$ROOT/Resources/frames" "$RES/"
# Borders and icon come from the Electron app's assets rather than a second copy
ASSETS="$(dirname "$ATLAS")"
cp "$ASSETS/orc-borders.png" "$ASSETS/orc-dock-icon.png" "$RES/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PeonPet</string>
  <key>CFBundleDisplayName</key><string>Peon Pet</string>
  <key>CFBundleIdentifier</key><string>com.martinsmith.peonpet</string>
  <key>CFBundleExecutable</key><string>PeonPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for SMAppService and for a stable identity
codesign --force --sign - --identifier com.martinsmith.peonpet "$APP" 2>/dev/null || true

echo "OK -> $APP"
du -sh "$APP"
