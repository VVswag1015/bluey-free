#!/bin/zsh
# Packs Bluey into build/Bluey.dmg: open it, then drag Bluey onto Applications.
# Builds the app first (scripts/build-mac.sh), so this one command does everything.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-mac.sh

APP="build/Bluey.app"
DMG="build/Bluey.dmg"
[[ -d "$APP" ]] || { echo "Missing $APP; the build step did not produce it" >&2; exit 1; }

# Stage outside the project (iCloud-synced folders attach Finder info that can break signing).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# ditto copies the app without disturbing its code signature.
ditto --norsrc --noextattr "$APP" "$STAGE/Bluey.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Bluey" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" > /dev/null

echo "Built $DMG"
echo "Open it, then drag Bluey onto the Applications folder."
