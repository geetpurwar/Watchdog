#!/bin/bash
# Build Watchdog.app. With --install: copy to /Applications and register it to start at login.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -5

APP=build/Watchdog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Watchdog "$APP/Contents/MacOS/Watchdog"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Watchdog</string>
    <key>CFBundleDisplayName</key><string>Watchdog</string>
    <key>CFBundleIdentifier</key><string>com.geetpurwar.watchdog</string>
    <key>CFBundleExecutable</key><string>Watchdog</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppSleepDisabled</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Geet Purwar</string>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# A stable signing identity keeps the notification permission across rebuilds.
# Ad-hoc signatures change with every build, so macOS would treat each build as a new app.
SIGN_ID="${WATCHDOG_SIGN_ID:-418A40C53F4E65CBC304DEC2D6C9C5E33700759B}"   # Developer ID Application: Geet Purwar
# (No `cmd | grep -q` here: under pipefail an early grep exit fails the pipeline.)
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGNED_OK=0
if [[ "$IDENTITIES" == *"$SIGN_ID"* ]]; then
    if perl -e 'alarm 30; exec @ARGV' codesign --force --timestamp=none --sign "$SIGN_ID" "$APP" 2>/dev/null; then
        DETAILS="$(codesign -dvv "$APP" 2>&1 || true)"
        [[ "$DETAILS" == *"Authority=Developer ID"* ]] && SIGNED_OK=1
    fi
fi
if [[ "$SIGNED_OK" == 1 ]]; then
    echo "signed with Developer ID"
else
    codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
    echo "signed ad-hoc (notification permission may be asked again after a rebuild)"
fi
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    LABEL=com.geetpurwar.watchdog
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    # Only the installed copy; a raw test binary with the same name is left alone.
    pgrep -f "^/Applications/Watchdog.app/Contents/MacOS/Watchdog$" | xargs -I{} kill {} 2>/dev/null || true
    rm -rf /Applications/Watchdog.app
    cp -R "$APP" /Applications/Watchdog.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Watchdog.app
    /Applications/Watchdog.app/Contents/MacOS/Watchdog --enable-login
    sleep 2
    launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|pid" | head -3
    echo "installed /Applications/Watchdog.app and registered $LABEL"
fi
