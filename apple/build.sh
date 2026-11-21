#!/bin/bash
# Builds the macOS app with ad-hoc signing (no Apple developer team) into apple/build/Lynx Reminders.app.
#   ./build.sh            Release build
#   CONFIG=Debug ./build.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

CONFIG="${CONFIG:-Release}"
APP="Lynx Reminders.app"
OUT="$DIR/build"

# Regenerate the project when XcodeGen is installed (the generated .xcodeproj is committed too).
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
fi

echo "Building $APP ($CONFIG) ..."
xcodebuild \
    -project LynxReminders.xcodeproj \
    -scheme LynxReminders-macOS \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    -quiet \
    build

rm -rf "$OUT/$APP"
cp -R "$OUT/DerivedData/Build/Products/$CONFIG/$APP" "$OUT/$APP"
# Config/Supabase.local.json (git-ignored, optional) replaces the hosted project, e.g. the local stack.
if [ -f Config/Supabase.local.json ]; then
    cp Config/Supabase.local.json "$OUT/$APP/Contents/Resources/Supabase.json"
    echo "Using Config/Supabase.local.json"
fi
codesign --force --deep --sign - "$OUT/$APP" 2>/dev/null || true
# Ad-hoc signatures default to "this exact binary" (cdhash), so macOS treats every rebuild as a new
# app for notifications: alerts an older build scheduled keep firing and the new build can't remove
# them. A designated requirement on the bundle id keeps one identity across rebuilds.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUT/$APP/Contents/Info.plist")
codesign --force --sign - -r "=designated => identifier \"$BUNDLE_ID\"" "$OUT/$APP"

echo "Done: $OUT/$APP"
