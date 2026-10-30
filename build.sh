#!/bin/zsh
# Builds "AI Monitor for Claude.app" in build/, then installs it in
# ~/Applications and launches it.
# With --build-only it only builds (used by the Homebrew formula).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.2"
NAME="AI Monitor for Claude"
EXEC="AIMonitorForClaude"
BUNDLE_ID="net.gauteweb.aimonitor"
APP="build/$NAME.app"

ICON_SOURCE="ai-monitor-icon-512.png"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/$EXEC" Sources/main.swift

# App icon: scale the 512 px source to every size macOS uses and pack it as .icns.
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if (( size < 512 )); then
        sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
