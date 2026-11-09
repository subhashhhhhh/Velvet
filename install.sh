#!/bin/zsh
# Builds Velvet (Release) and installs it to /Applications.
# Safe while Velvet is running: the new bundle is swapped in atomically, the running copy
# keeps its already-loaded code, and the next launch uses the new version.
set -euo pipefail
cd "$(dirname "$0")"
DD="${VELVET_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Velvet-install}"
# Xcode 27+ opens Velvet.xcodeproj (new format). Older Xcode (26, on macOS 15) uses a classic
# project generated from project.yml.
PROJECT=Velvet.xcodeproj
XCODE_MAJOR=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ { split($2, v, "."); print v[1] }')
if [ -z "$XCODE_MAJOR" ]; then echo "Xcode is not installed (xcodebuild not found)."; exit 1; fi
if [ "$XCODE_MAJOR" -lt 27 ]; then
  command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
  xcodegen generate --quiet
  PROJECT=Velvet-Xcode26.xcodeproj
fi
# Each install gets its own build number (the commit count), so macOS notices the update and
# refreshes cached data such as the Dock's icon.
BUILD_NUMBER=$(git -C "$(dirname "$0")" rev-list --count HEAD 2>/dev/null || date +%s)

# Sign with the release certificate when it's in the keychain (docs/signing.md): macOS then
# sees every build as the same app (permissions stay granted), and the in-app updater can
# install releases over it. Without it the build is signed ad hoc.
SIGNING=()
if security find-identity -p codesigning | grep -q '"Velvet Self-Signed"'; then
  SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Velvet Self-Signed" DEVELOPMENT_TEAM="" OTHER_CODE_SIGN_FLAGS="--timestamp=none")
fi

xcodebuild -project "$PROJECT" -scheme Velvet -configuration Release -derivedDataPath "$DD" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${SIGNING[@]}" build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="$DD/Build/Products/Release/Velvet.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }
STAGE="/Applications/.Velvet-staging.app"
rm -rf "$STAGE"
ditto "$APP" "$STAGE"
codesign --verify --deep "$STAGE"
# Atomic swap: the old bundle moves aside (still usable by a running process), the new one takes its name.
if [ -d /Applications/Velvet.app ]; then
  rm -rf /Applications/.Velvet-old.app
  mv /Applications/Velvet.app /Applications/.Velvet-old.app
fi
mv "$STAGE" /Applications/Velvet.app
rm -rf /Applications/.Velvet-old.app
# Re-register with LaunchServices so the Dock and launchers pick up the new icon and version.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Velvet.app >/dev/null 2>&1 || true
echo "Installed $(git rev-parse --short HEAD) to /Applications/Velvet.app"
pgrep -x Velvet >/dev/null && echo "Velvet is running: relaunch it to use the new version." || true
