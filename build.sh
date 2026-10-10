#!/bin/bash
set -e

APP_NAME="MIDIRecorder"
BUNDLE_DIR="${APP_NAME}.app"

# 1. Clean previous build & prepare directories
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"
mkdir -p AppIcon.appiconset

# 2. Render SVG to transparent 1024x1024 PNG if SVG exists
if [ -f "AppIcon.svg" ]; then
    if command -v rsvg-convert &> /dev/null; then
        rsvg-convert -w 1024 -h 1024 -f png AppIcon.svg -o AppIcon.appiconset/icon_1024.png
    else
        qlmanage -t -s 1024 -o /tmp AppIcon.svg > /dev/null 2>&1
        mv /tmp/AppIcon.svg.png AppIcon.appiconset/icon_1024.png
    fi
fi

# Render small menu bar icon (~22px) from SVG
if [ -f "AppIcon.svg" ]; then
    if command -v rsvg-convert &> /dev/null; then
        rsvg-convert -w 22 -h 22 -f png AppIcon.svg -o "${BUNDLE_DIR}/Contents/Resources/menuBar.png"
    else
        qlmanage -t -s 22 -o /tmp AppIcon.svg > /dev/null 2>&1
        mv /tmp/AppIcon.svg.png "${BUNDLE_DIR}/Contents/Resources/menuBar.png"
    fi
fi

# Write Contents.json if missing
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

# 4. Compile Asset Catalog with actool
actool Assets.xcassets \
  --compile "${BUNDLE_DIR}/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist /tmp/appicon_partial.plist > /dev/null

rm -f /tmp/appicon_partial.plist

# 5. Generate .icns fallback preserving transparency
if [ -f "AppIcon.appiconset/icon_1024.png" ]; then
    mkdir -p /tmp/AppIcon.iconset
    sips -z 1024 1024 AppIcon.appiconset/icon_1024.png --out /tmp/AppIcon.iconset/icon_512x512@2x.png > /dev/null 2>&1
    sips -z 512 512   AppIcon.appiconset/icon_1024.png --out /tmp/AppIcon.iconset/icon_512x512.png > /dev/null 2>&1
    sips -z 256 256   AppIcon.appiconset/icon_1024.png --out /tmp/AppIcon.iconset/icon_256x256.png > /dev/null 2>&1
    sips -z 128 128   AppIcon.appiconset/icon_1024.png --out /tmp/AppIcon.iconset/icon_128x128.png > /dev/null 2>&1
    sips -z 32 32     AppIcon.appiconset/icon_1024.png --out /tmp/AppIcon.iconset/icon_32x32.png > /dev/null 2>&1
    sips -z 16 16     AppIcon.appiconset/icon_1024.png --out /tmp/AppIcon.iconset/icon_16x16.png > /dev/null 2>&1
    iconutil -c icns /tmp/AppIcon.iconset -o "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
    rm -rf /tmp/AppIcon.iconset
fi

# 6. Compile Swift Application
swiftc -O \
  -parse-as-library \
  -framework SwiftUI \
  -framework CoreMIDI \
  -framework AudioToolbox \
  -framework ServiceManagement \
  MainApp.swift \
  -o "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

strip "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

# 7. Write Info.plist
cat <<'EOF' > "${BUNDLE_DIR}/Contents/Info.plist"
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
    <string>com.user.midirecorder</string>
    <key>CFBundleName</key>
    <string>MIDI Recorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# 8. Sign and Refresh Cache
codesign --force --deep --sign - "$BUNDLE_DIR"
touch "$BUNDLE_DIR"
qlmanage -r > /dev/null 2>&1 || true

echo "App built successfully!"
