#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --scratch-path .build --cache-path .build/cache
SIDEBRIEF_BIN_DIR="$(swift build -c release --disable-sandbox --scratch-path .build --cache-path .build/cache --show-bin-path)"
SIDEBRIEF_APP="$PWD/dist/SideBrief.app"
mkdir -p "$SIDEBRIEF_APP/Contents/MacOS" "$SIDEBRIEF_APP/Contents/Resources"
cp "$SIDEBRIEF_BIN_DIR/SideBrief" "$SIDEBRIEF_APP/Contents/MacOS/SideBrief.new"
mv -f "$SIDEBRIEF_APP/Contents/MacOS/SideBrief.new" "$SIDEBRIEF_APP/Contents/MacOS/SideBrief"
cat > "$SIDEBRIEF_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SideBrief</string>
<key>CFBundleDisplayName</key><string>SideBrief · 侧读</string>
<key>CFBundleIdentifier</key><string>app.sidebrief.desktop</string>
<key>CFBundleExecutable</key><string>SideBrief</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>SideBrief contributors</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --deep --sign - "$SIDEBRIEF_APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SIDEBRIEF_APP" "$PWD/dist/SideBrief-macOS.zip"
printf 'Built: %s\n' "$SIDEBRIEF_APP"
