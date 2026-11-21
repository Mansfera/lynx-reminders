#!/bin/bash
# Rebuilds the app icon from generate.py: apple/Resources/AppIcon.icon (Xcode compiles it, with
# fallbacks for older systems), the Android drawables, and preview.png: macOS (top) and iOS rows in
# Default, Dark, Clear light, Clear dark, Tinted light, Tinted dark.
# Requires: uv (for shapely), Xcode 26+ (Icon Composer's ictool), ImageMagick.
set -euo pipefail
cd "$(dirname "$0")"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

uv run --quiet --with shapely python generate.py

ICON=../../apple/Resources/AppIcon.icon
mkdir -p previews
for platform in macOS iOS; do
    for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
        "$ICTOOL" "$ICON" --export-image --output-file "previews/$platform-$rendition.png" \
            --platform "$platform" --rendition "$rendition" --width 256 --height 256 --scale 1 >/dev/null
    done
done
magick previews/macOS-{Default,Dark,ClearLight,ClearDark,TintedLight,TintedDark}.png +append previews/row-macOS.png
magick previews/iOS-{Default,Dark,ClearLight,ClearDark,TintedLight,TintedDark}.png +append previews/row-iOS.png
magick previews/row-macOS.png previews/row-iOS.png -append preview.png
rm -rf previews
echo "✅ Icon rebuilt (preview: shared/icon/preview.png)"
