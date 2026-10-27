#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/dist}"
app_dir="$output_dir/VPN Country Flag.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -framework Cocoa \
  -framework ServiceManagement \
  -framework SystemConfiguration \
  -framework UserNotifications \
  "$project_dir/Sources/main.m" \
  -o "$app_dir/Contents/MacOS/VPNCountryFlag"
cp "Info.plist" "$app_dir/Contents/Info.plist"
cp "PkgInfo" "$app_dir/Contents/PkgInfo"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/VPNCountryFlag.icns"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
