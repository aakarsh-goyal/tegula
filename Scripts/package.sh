#!/bin/bash
# Builds and zips build/Tegula.app for a GitHub release / Homebrew cask. Prints the sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
Scripts/build.sh >/dev/null
ZIP="build/Tegula-$VERSION-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Tegula.app "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP" | awk '{print $1}'
