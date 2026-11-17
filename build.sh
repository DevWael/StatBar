#!/bin/sh
# Builds build/StatBar.app. Pass "install" to copy it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/StatBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -wmo -swift-version 5 \
    -import-objc-header Sources/Bridge.h \
    Sources/*.swift \
    -lIOReport -framework AppKit -framework IOKit \
    -o "$APP/Contents/MacOS/StatBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [ "$1" = "install" ]; then
    rm -rf ~/Applications/StatBar.app
    cp -R "$APP" ~/Applications/
    echo "Installed ~/Applications/StatBar.app"
fi
