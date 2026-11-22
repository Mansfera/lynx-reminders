#!/bin/bash
# Builds the iOS app signed with a free Apple ID ("Personal Team", no paid developer account) and
# installs it on a connected iPhone.
#   ./build-ios.sh                 Release build, installed on the first connected iPhone
#   DEVICE="iPhone 13 mini" ./build-ios.sh
#   TEAM=ABCDE12345 ./build-ios.sh (otherwise the free team is read from Xcode's accounts)
#   CONFIG=Debug ./build-ios.sh
#
# One-time setup: add your Apple ID in Xcode > Settings > Apple Accounts, connect the iPhone and
# trust this Mac, and turn on Settings > Privacy & Security > Developer Mode on the phone.
# Free-team builds expire after 7 days: run this again to refresh it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

CONFIG="${CONFIG:-Release}"
OUT="$DIR/build/ios"

if [ -z "${TEAM:-}" ]; then
    # Xcode keeps the signed-in accounts' teams here; pick the free (personal) one.
    TEAM=$(defaults export com.apple.dt.Xcode - 2>/dev/null \
        | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null \
        | /usr/bin/python3 -c 'import json,sys
teams=[t for v in json.load(sys.stdin).values() for t in v]
free=[t for t in teams if t.get("isFreeProvisioningTeam")] or teams
print(free[0]["teamID"] if free else "")' 2>/dev/null || true)
fi
if [ -z "$TEAM" ]; then
    # Newer Xcode doesn't cache teams there; the Apple Development certificate's OU is the team id.
    TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *//p' | head -1 || true)
fi
if [ -z "$TEAM" ]; then
    # Or the team picked in Xcode's Signing & Capabilities tab.
    TEAM=$(grep -m1 -oE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' LynxReminders.xcodeproj/project.pbxproj 2>/dev/null \
        | sed -E 's/.* = ([A-Z0-9]+);/\1/' || true)
fi
if [ -z "$TEAM" ]; then
    echo "No Apple ID team found. Open LynxReminders.xcodeproj, pick the LynxReminders-iOS target > Signing & Capabilities > Team > (Personal Team), then run this again (or set TEAM=...)." >&2
    exit 1
fi

# The phone to install on: DEVICE (name or identifier), else the first connected iPhone.
DEVICES_JSON=$(mktemp)
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --quiet --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
DEVICE_ID=$(/usr/bin/python3 -c 'import json,os,sys
want=os.environ.get("DEVICE","")
for d in json.load(sys.stdin)["result"]["devices"]:
    props=d.get("deviceProperties",{}); hw=d.get("hardwareProperties",{})
    if want and want not in (props.get("name"), d.get("identifier"), hw.get("udid")): continue
    if not want and hw.get("deviceType")!="iPhone": continue
    if d.get("connectionProperties",{}).get("tunnelState")=="unavailable": continue
    print(d["identifier"], hw.get("udid","")); break' <"$DEVICES_JSON" 2>/dev/null || true)
read -r DEVICE_ID DEVICE_UDID <<<"$DEVICE_ID"
if [ -z "$DEVICE_ID" ]; then
    echo "No connected iPhone found. Connect it by USB (or the same Wi-Fi), unlock it and trust this Mac." >&2
    exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
fi

echo "Building Lynx Reminders for iOS ($CONFIG, team $TEAM) ..."
xcodebuild \
    -project LynxReminders.xcodeproj \
    -scheme LynxReminders-iOS \
    -configuration "$CONFIG" \
    -destination "id=$DEVICE_UDID" \
    -derivedDataPath "$OUT/DerivedData" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    -quiet \
    build

APP="$OUT/DerivedData/Build/Products/$CONFIG-iphoneos/Lynx Reminders.app"
echo "Installing on $DEVICE_ID ..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "Done. First run: on the iPhone open Settings > General > VPN & Device Management and trust your Apple ID."
