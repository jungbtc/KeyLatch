#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="${KEYLATCH_BUILD_APP:-build/KeyLatch.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BUILD_CACHE="build/swift-module-cache"
mkdir -p "$BUILD_CACHE"
swiftc -swift-version 5 -module-cache-path "$BUILD_CACHE" -target "$(uname -m)-apple-macosx13.0" -O -framework AppKit -framework ApplicationServices main.swift -o "$APP/Contents/MacOS/KeyLatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KeyLatch</string>
<key>CFBundleIdentifier</key><string>local.keylatch.app</string>
<key>CFBundleName</key><string>KeyLatch</string>
<key>CFBundleDisplayName</key><string>KeyLatch</string>
<key>CFBundleIconFile</key><string>KeyLatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -f Assets/KeyLatch.icns ]]; then
    cp Assets/KeyLatch.icns "$APP/Contents/Resources/KeyLatch.icns"
fi
if [[ -n "${KEYLATCH_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$KEYLATCH_SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
"$APP/Contents/MacOS/KeyLatch" --self-test
echo "Built $APP (the installed copy was not replaced)"
