#!/bin/zsh
#
# Builds the release: one build for Apple silicon, one for Intel (each download stays small).
#
#   scripts/release.sh            build the DMGs and zips into dist/
#   scripts/release.sh --publish  also create the GitHub release, update
#                                 updates/latest.json and the Homebrew cask
#
# The version comes from MARKETING_VERSION in the project. Release notes for
# --publish are read from dist/notes-<version>.md: the changelog only; the
# download and install instructions are appended here.
#
# Every build is signed with the "Velvet Self-Signed" certificate in the login
# keychain (docs/signing.md). The in-app updater only installs a download signed
# with the same certificate as the running app, so it must never change.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

PROJECT=Velvet.xcodeproj
XCODE_MAJOR=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ { split($2, v, "."); print v[1] }')
if [[ "$XCODE_MAJOR" -lt 27 ]]; then
  xcodegen generate --quiet
  PROJECT=Velvet-Xcode26.xcodeproj
fi

setting() {
  xcodebuild -project "$PROJECT" -scheme Velvet -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' "/ $1 = / { print \$2; exit }"
}
VERSION=$(setting MARKETING_VERSION)
MIN_MACOS=$(setting MACOSX_DEPLOYMENT_TARGET)
[[ -n "$VERSION" ]] || { echo "Could not read MARKETING_VERSION" >&2; exit 1; }
# The updater compares versions as up to three numbers.
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "Version $VERSION isn't like 1.2 or 1.2.3" >&2; exit 1; }

IDENTITY="Velvet Self-Signed"
REPO="subhashhhhhh/Velvet"
TAP_REPO="subhashhhhhh/homebrew-velvet"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" \
  || { echo "The \"$IDENTITY\" signing identity isn't in the keychain (see docs/signing.md)" >&2; exit 1; }

if [[ "${1:-}" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first" >&2; exit 1; }
  ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 || { echo "v$VERSION is already released; raise MARKETING_VERSION" >&2; exit 1; }
fi

mkdir -p "$DIST"
BUILD_NUMBER=$(git rev-list --count HEAD)
echo "Velvet $VERSION ($BUILD_NUMBER), macOS $MIN_MACOS+"

# arch   label (used in the file names and by the updater)
for pair in "arm64 AppleSilicon" "x86_64 Intel"; do
  arch=${pair%% *}
  label=${pair##* }
  derived="$BUILD/$arch"
  echo "\n==> Building $label ($arch)"
  xcodebuild -project "$PROJECT" -scheme Velvet -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    ARCHS="$arch" ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    DEPLOYMENT_POSTPROCESSING=YES ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
    build -quiet

  app="$derived/Build/Products/Release/Velvet.app"
  binary="$app/Contents/MacOS/Velvet"

  # Each download must contain exactly the processor its name promises.
  [[ "$(lipo -archs "$binary")" == "$arch" ]] || { echo "Expected $arch, built: $(lipo -archs "$binary")" >&2; exit 1; }
  minos=$(vtool -show-build "$binary" | awk '/minos/ { print $2; exit }')
  [[ "$minos" == "$MIN_MACOS" ]] || { echo "Expected minimum macOS $MIN_MACOS, got $minos" >&2; exit 1; }
  codesign --verify --deep --strict "$app"
  [[ "$(codesign -dvv "$app" 2>&1)" == *"Authority=$IDENTITY"* ]] || { echo "$app isn't signed with $IDENTITY" >&2; exit 1; }

  # The updater downloads the zip; people download the disk image.
  zip="$DIST/Velvet-$VERSION-$label.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"

  staging="$BUILD/dmg-$arch"
  mkdir -p "$staging"
  ditto "$app" "$staging/Velvet.app"
  ln -s /Applications "$staging/Applications"
  dmg="$DIST/Velvet-$VERSION-$label.dmg"
  rm -f "$dmg"
  hdiutil create -quiet -volname "Velvet $VERSION" -srcfolder "$staging" -format UDZO -imagekey zlib-level=9 "$dmg"
  hdiutil verify -quiet "$dmg"
  echo "    $(basename "$dmg")  $(du -h "$dmg" | cut -f1 | xargs)"
  echo "    $(basename "$zip")  $(du -h "$zip" | cut -f1 | xargs)"
done

assets=(Velvet-$VERSION-AppleSilicon.dmg Velvet-$VERSION-Intel.dmg Velvet-$VERSION-AppleSilicon.zip Velvet-$VERSION-Intel.zip)
(cd "$DIST" && shasum -a 256 $assets | tee "SHA256SUMS-$VERSION.txt")

[[ "${1:-}" == "--publish" ]] || exit 0

notes="$DIST/notes-$VERSION.md"
[[ -f "$notes" ]] || { echo "Missing $notes" >&2; exit 1; }
body="$BUILD/body.md"
{
  cat "$notes"
  # The app shows the notes above this marker and drops the rest.
  print -- "\n<!-- velvet:install -->\n\n---\n"
  print -- "### Install\n"
  print -- "**Homebrew** (recommended; no Gatekeeper prompt):"
  print -- '```bash\nbrew install --cask subhashhhhhh/velvet/velvet\n```\n'
  print -- "**Or download the disk image for your Mac:**"
  print -- "- Apple silicon (M1 and later): \`Velvet-$VERSION-AppleSilicon.dmg\`"
  print -- "- Intel: \`Velvet-$VERSION-Intel.dmg\`\n"
  print -- "Not sure which you have? Apple menu › **About This Mac** › **Chip** (Apple silicon) or **Processor** (Intel). Velvet needs macOS $MIN_MACOS or later.\n"
  print -- "Velvet isn't notarized by Apple, so the first time you open a downloaded copy macOS blocks it. Open **System Settings › Privacy & Security**, scroll to **Security** and click **Open Anyway**, or run:"
  print -- '```bash\nxattr -cr /Applications/Velvet.app\n```\n'
  print -- "Velvet updates itself from **Settings › About**. Checksums are in \`SHA256SUMS-$VERSION.txt\`."
} > "$body"

echo "\n==> Publishing v$VERSION"
gh release create "v$VERSION" "${assets[@]/#/$DIST/}" "$DIST/SHA256SUMS-$VERSION.txt" \
  --repo "$REPO" --target main --title "Velvet $VERSION" --notes-file "$body"

echo "\n==> Updating updates/latest.json"
# The in-app updater reads this through raw.githubusercontent.com, which, unlike
# GitHub's API, isn't limited to 60 requests an hour per network.
mkdir -p "$ROOT/updates"
/usr/bin/python3 -I - "$VERSION" "$notes" "$DIST" "$ROOT/updates/latest.json" <<'PY'
import hashlib, json, os, sys
version, notes, dist, out = sys.argv[1:]
archives = {}
for label in ("AppleSilicon", "Intel"):
    name = f"Velvet-{version}-{label}.zip"
    path = os.path.join(dist, name)
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    archives[label] = {"name": name, "size": os.path.getsize(path), "sha256": digest}
manifest = {"version": version, "tag": f"v{version}", "notes": open(notes).read().strip(), "archives": archives}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
git -C "$ROOT" add updates/latest.json
git -C "$ROOT" commit -qm "Update manifest for $VERSION"
git -C "$ROOT" push -q
echo "    updates/latest.json → $VERSION"

echo "\n==> Updating the Homebrew cask"
sha_arm=$(shasum -a 256 "$DIST/Velvet-$VERSION-AppleSilicon.dmg" | cut -d' ' -f1)
sha_intel=$(shasum -a 256 "$DIST/Velvet-$VERSION-Intel.dmg" | cut -d' ' -f1)
tap="$BUILD/tap"
gh repo clone "$TAP_REPO" "$tap" -- --quiet --depth 1
sed -E -i '' \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 arm: +\"[0-9a-f]*\",/  sha256 arm:   \"$sha_arm\",/" \
  -e "s/^         intel: \"[0-9a-f]*\"/         intel: \"$sha_intel\"/" \
  "$tap/Casks/velvet.rb"
grep -q "$sha_arm" "$tap/Casks/velvet.rb" && grep -q "$sha_intel" "$tap/Casks/velvet.rb" \
  || { echo "Couldn't update $tap/Casks/velvet.rb" >&2; exit 1; }
git -C "$tap" commit -qam "Velvet $VERSION"
git -C "$tap" push -q
echo "    $TAP_REPO → $VERSION"
