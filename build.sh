#!/bin/zsh
# Builds "AI Monitor for Claude.app" and installs it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

NAME="AI Monitor for Claude"
EXEC="AIMonitorForClaude"
APP="build/$NAME.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/$EXEC" Sources/main.swift

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$EXEC</string>
    <key>CFBundleIdentifier</key><string>local.claudestatus</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.9</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

mkdir -p ~/Applications
pkill -x "$EXEC" 2>/dev/null || true
# Remove the build from before the rename.
pkill -x ClaudeStatus 2>/dev/null || true
rm -rf ~/Applications/ClaudeStatus.app
rm -rf ~/Applications/"$NAME.app"
cp -R "$APP" ~/Applications/
open ~/Applications/"$NAME.app"
echo "Installert og startet: ~/Applications/$NAME.app"
