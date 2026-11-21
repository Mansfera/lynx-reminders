#!/bin/bash
# Compiles the iOS target for the simulator without a simulator runtime installed.
# (A scheme build needs a destination, which needs the iOS platform component; a target build doesn't.
#  The asset catalog is skipped because actool needs a runtime.)
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
xcodebuild -project LynxReminders.xcodeproj -target LynxReminders-iOS -sdk iphonesimulator -configuration Debug \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    SYMROOT="$DIR/build/ios-sym" OBJROOT="$DIR/build/ios-obj" EXCLUDED_SOURCE_FILE_NAMES="Assets.xcassets" \
    build "$@"
