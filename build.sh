#!/bin/zsh
# Builds "AI Monitor for Claude.app" in build/, then installs it in
# ~/Applications and launches it.
# With --build-only it only builds (used by the Homebrew formula).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.9"
NAME="AI Monitor for Claude"
EXEC="AIMonitorForClaude"
BUNDLE_ID="net.gauteweb.aimonitor"
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
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

if [[ "${1:-}" == "--build-only" ]]; then
    echo "Built: $APP"
    exit 0
fi

mkdir -p ~/Applications
pkill -x "$EXEC" 2>/dev/null || true
rm -rf ~/Applications/"$NAME.app"
cp -R "$APP" ~/Applications/
open ~/Applications/"$NAME.app"
echo "Installed and launched: ~/Applications/$NAME.app"
