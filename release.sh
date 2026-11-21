#!/bin/bash
# Builds the macOS DMG and the Android APK for <version>, commits the version bump (signed), pushes,
# and publishes a GitHub release with both files.
set -euo pipefail
usage() { echo "usage: ./release.sh <version>, e.g. ./release.sh 0.2.0"; exit 1; }
[ $# -eq 1 ] || usage
V="$1"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
cd "$(dirname "$0")"
REPO=Mansfera/lynx-reminders

[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
gh release view "v$V" -R "$REPO" >/dev/null 2>&1 && { echo "v$V is already released."; exit 1; }
# Local-stack overrides would ship a build that talks to 127.0.0.1 / 10.0.2.2.
for f in apple/Config/Supabase.local.json android/supabase.local.properties; do
    [ -f "$f" ] && { echo "$f points the build at the local stack: rename it (e.g. to *.local.off.*) first."; exit 1; }
done

# Version bump: build numbers count from the last commit. A rerun after a failed publish finds
# "Release $V" already committed and reuses it instead of bumping twice.
VERSION_FILES=(apple/project.yml apple/LynxReminders.xcodeproj/project.pbxproj android/app/build.gradle.kts)
if [ "$(git log -1 --format=%s)" = "Release $V" ]; then
    echo "Release $V is already committed: rebuilding and publishing it."
else
    # If anything fails before the release commit, put the version files back so a rerun starts clean.
    trap 'git checkout -- "${VERSION_FILES[@]}" 2>/dev/null && echo "Stopped before the release commit: version bump undone."' EXIT
    BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' apple/project.yml) + 1 ))
    CODE=$(( $(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' android/app/build.gradle.kts) + 1 ))
    sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$V\"/" \
              -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" apple/project.yml
    sed -i '' -e "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $V;/" \
              -e "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $BUILD;/" apple/LynxReminders.xcodeproj/project.pbxproj
    sed -i '' -e "s/versionCode = [0-9]*/versionCode = $CODE/" \
              -e "s/versionName = \".*\"/versionName = \"$V\"/" android/app/build.gradle.kts
fi

rm -rf dist && mkdir -p dist

# macOS: ad-hoc signed app in a DMG with an Applications shortcut
(cd apple && ./build.sh)
APP="apple/build/Lynx Reminders.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$V" ] \
    || { echo "The Mac app isn't version $V."; exit 1; }
STAGE=apple/build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Lynx Reminders.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Lynx-Reminders-$V.dmg"
hdiutil create -volname "Lynx Reminders" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Android: debug-signed APK (no release key yet), installable by sideloading
(cd android && ./gradlew :app:assembleDebug --console=plain -q)
grep -q 'SUPABASE_URL = "https://' android/app/build/generated/source/buildConfig/debug/com/mansfera/lynxreminders/BuildConfig.java \
    || { echo "The APK doesn't point at the hosted project."; exit 1; }
APK="dist/Lynx-Reminders-$V.apk"
cp android/app/build/outputs/apk/debug/app-debug.apk "$APK"

(cd dist && shasum -a 256 "$(basename "$DMG")" "$(basename "$APK")") > dist/SHA256SUMS.txt
cat dist/SHA256SUMS.txt

if [ "$(git log -1 --format=%s)" != "Release $V" ]; then
    # The signing touch times out after a few seconds, and the builds before it take minutes.
    read -r -p "Builds done. Press Enter, then touch your YubiKey when it blinks to sign the release commit. "
    git add "${VERSION_FILES[@]}"
    git commit -m "Release $V"
    trap - EXIT
fi
git push

NOTES="**macOS** (Apple silicon and Intel, macOS 14+): open \`$(basename "$DMG")\` and drag Lynx Reminders to Applications. The app is not notarized, so the first launch is blocked: open it once, then choose **Open Anyway** in System Settings → Privacy & Security.

**Android** (Android 10 or later): download \`$(basename "$APK")\` on the phone and allow installing from your browser when asked. It is a debug-signed build, so a future Play Store version won't install over it.

Checksums are in \`SHA256SUMS.txt\`."
gh release create "v$V" "$DMG" "$APK" dist/SHA256SUMS.txt -R "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Lynx Reminders $V" --notes "$NOTES"
echo "✅ Released $V: https://github.com/$REPO/releases/tag/v$V"
