#!/bin/bash
# Builds dist/Taskboard.app (ad hoc signed): the menu bar app and taskboard-mcp next to it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
APP=dist/Taskboard.app

swift build -c release --product Taskboard
swift build -c release --product taskboard-mcp
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Taskboard" "$BIN/taskboard-mcp" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.lozhka13.taskboard</string>
  <key>CFBundleName</key><string>Taskboard</string>
  <key>CFBundleExecutable</key><string>Taskboard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Taskboard записывает голосовую заметку по F13.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Taskboard расшифровывает голосовые заметки на этом маке.</string>
</dict>
</plist>
PL

codesign --force --deep --sign - "$APP"
echo "Built $APP"
