#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="MIDIRecorder"
BUNDLE_DIR="${APP_NAME}.app"
MIN_MACOS="13.0"
BUNDLE_ID="com.user.midirecorder"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

[ -f AppIcon.svg ] || { echo "AppIcon.svg not found" >&2; exit 1; }

# render SIZE OUT: SVG -> square PNG. The qlmanage fallback may not keep transparency.
render() {
    if command -v rsvg-convert &> /dev/null; then
        rsvg-convert -w "$1" -h "$1" -f png AppIcon.svg -o "$2"
    else
        qlmanage -t -s "$1" -o "$T" AppIcon.svg > /dev/null 2>&1 || { echo "qlmanage failed to render AppIcon.svg" >&2; exit 1; }
        mv "$T/AppIcon.svg.png" "$2"
    fi
}

# 1. Clean previous build & prepare directories
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"
mkdir -p AppIcon.appiconset

# 2. Render icons
render 1024 AppIcon.appiconset/icon_1024.png
# Menu bar icon is shown at 18pt (see AppDelegate), so 36px covers Retina
render 36 "${BUNDLE_DIR}/Contents/Resources/menuBar.png"

# Always (re)write Contents.json
cat <<'EOF' > AppIcon.appiconset/Contents.json
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# 3. Setup Asset Catalog
mkdir -p Assets.xcassets
rm -rf Assets.xcassets/AppIcon.appiconset
cp -R AppIcon.appiconset Assets.xcassets/

# 4. Compile Asset Catalog with actool (show its output only on failure)
actool Assets.xcassets \
  --compile "${BUNDLE_DIR}/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target "$MIN_MACOS" \
  --app-icon AppIcon \
  --output-partial-info-plist "$T/appicon_partial.plist" > "$T/actool.log" 2>&1 \
  || { cat "$T/actool.log" >&2; exit 1; }

# 5. Generate .icns fallback preserving transparency
mkdir "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.appiconset/icon_1024.png --out "$T/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
    sips -z $((s * 2)) $((s * 2)) AppIcon.appiconset/icon_1024.png --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

# 6. Compile Swift Application as a universal binary targeting $MIN_MACOS
for arch in arm64 x86_64; do
    swiftc -O \
      -parse-as-library \
      -target "${arch}-apple-macos${MIN_MACOS}" \
      -framework SwiftUI \
      -framework CoreMIDI \
      -framework AudioToolbox \
      -framework ServiceManagement \
      MainApp.swift \
      -o "$T/${APP_NAME}-${arch}"
done
lipo -create "$T/${APP_NAME}-arm64" "$T/${APP_NAME}-x86_64" -output "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

strip "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

# 7. Write Info.plist
cat <<EOF > "${BUNDLE_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MIDIRecorder</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>MIDI Recorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# 8. Sign. An ad-hoc signature's default requirement is the code hash, which
# changes every build, so macOS may re-ask for Documents access and Launch at
# Login approval. Fix: set SIGN_IDENTITY to a certificate name from
# `security find-identity -v -p codesigning` (stable across builds). Without
# one, ad-hoc sign with an explicit bundle-id requirement instead of the hash.
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"
else
    codesign --force --sign - \
      --requirements "=designated => identifier \"${BUNDLE_ID}\"" "$BUNDLE_DIR"
fi
touch "$BUNDLE_DIR"

echo "App built successfully!"
