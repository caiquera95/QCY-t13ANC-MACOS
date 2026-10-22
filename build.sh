#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/outputs/QCY Control.app"
mkdir -p "$PWD/work/module-cache"
STAGE=$(mktemp -d "$PWD/work/build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/QCY Control.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
xcrun swiftc -swift-version 6 -O -whole-module-optimization -target x86_64-apple-macosx14.0 -module-cache-path "$PWD/work/module-cache" Sources/*.swift -o "$BUNDLE/Contents/MacOS/QCYControl" -framework AppKit -framework SwiftUI -framework CoreBluetooth -framework CoreAudio
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/ThirdPartyLicenses.txt "$BUNDLE/Contents/Resources/ThirdPartyLicenses.txt"
/usr/bin/codesign --force --sign - "$BUNDLE"
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"
/usr/bin/codesign --verify --strict "$BUNDLE"
ditto "$BUNDLE" "$APP"
echo "Aplicativo criado: $APP"
