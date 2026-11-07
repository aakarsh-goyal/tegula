#!/bin/bash
# Builds build/Tegula.app. Pass --install to also copy it to /Applications (only when you mean it).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Tegula.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tegula "$APP/Contents/MacOS/Tegula"
# SwiftPM stamps the Mach-O with sdk == deployment target (15.0), so macOS treats the app as built for
# macOS 15 and keeps the legacy window chrome. We do compile against the current SDK; say so, keeping
# minos 15.0 so it still runs on Sequoia. (This is what makes traffic lights etc. adopt Liquid Glass.)
vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Tegula" "$APP/Contents/MacOS/Tegula"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/Slate.icns ] || [ Scripts/make-icons.swift -nt Resources/Slate.icns ]; then
  swift Scripts/make-icons.swift Resources
fi
cp Resources/Slate.icns Resources/Clay.icns "$APP/Contents/Resources/"
# Ad-hoc signature with a path-independent designated requirement, so the Accessibility grant
# survives rebuilds (TCC would otherwise key it to the changing code hash).
codesign --force --sign - --identifier com.aakarsh.tegula \
  -r='designated => identifier "com.aakarsh.tegula"' "$APP"
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
  pkill -x Tegula 2>/dev/null || true
  rm -rf /Applications/Tegula.app; cp -R "$APP" /Applications/Tegula.app
  echo "Installed /Applications/Tegula.app"
fi
