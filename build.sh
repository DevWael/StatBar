#!/bin/sh
# Builds build/StatBar.app. Pass "install" to copy it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/StatBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -wmo -swift-version 5 \
    -import-objc-header Sources/Bridge.h \
    Sources/*.swift \
    -lIOReport -framework AppKit -framework IOKit \
    -o "$APP/Contents/MacOS/StatBar"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
# Make Finder and Spotlight pick up the current icon instead of a cached one.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP"
if [ "$1" = "install" ]; then
    rm -rf ~/Applications/StatBar.app
    cp -R "$APP" ~/Applications/
    "$LSREGISTER" -f ~/Applications/StatBar.app
    echo "Installed ~/Applications/StatBar.app"
fi
