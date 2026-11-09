#!/bin/zsh
#
# Builds the release for Apple silicon.
#
#   scripts/release.sh            build the DMG and zip into dist/
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

derived="$BUILD/dd"
xcodebuild -project "$PROJECT" -scheme Velvet -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  DEPLOYMENT_POSTPROCESSING=YES ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  build -quiet

app="$derived/Build/Products/Release/Velvet.app"
binary="$app/Contents/MacOS/Velvet"

[[ "$(lipo -archs "$binary")" == "arm64" ]] || { echo "Expected an arm64-only binary" >&2; exit 1; }
minos=$(vtool -show-build "$binary" | awk '/minos/ { print $2; exit }')
[[ "$minos" == "$MIN_MACOS" ]] || { echo "Expected minimum macOS $MIN_MACOS, got $minos" >&2; exit 1; }
codesign --verify --deep --strict "$app"
[[ "$(codesign -dvv "$app" 2>&1)" == *"Authority=$IDENTITY"* ]] || { echo "$app isn't signed with $IDENTITY" >&2; exit 1; }

# The updater downloads the zip; people download the disk image.
zip="$DIST/Velvet-$VERSION-AppleSilicon.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

staging="$BUILD/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Velvet.app"
ln -s /Applications "$staging/Applications"
dmg="$DIST/Velvet-$VERSION-AppleSilicon.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Velvet $VERSION" -srcfolder "$staging" -format UDZO -imagekey zlib-level=9 "$dmg"
hdiutil verify -quiet "$dmg"
echo "    $(basename "$dmg")  $(du -h "$dmg" | cut -f1 | xargs)"
echo "    $(basename "$zip")  $(du -h "$zip" | cut -f1 | xargs)"

assets=(Velvet-$VERSION-AppleSilicon.dmg Velvet-$VERSION-AppleSilicon.zip)
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
  print -- "**Or download** \`Velvet-$VERSION-AppleSilicon.dmg\` below. Velvet needs a Mac with Apple silicon and macOS $MIN_MACOS or later.\n"
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
/usr/bin/python3 -I - "$VERSION" "$notes" "$zip" "$ROOT/updates/latest.json" <<'PY'
import hashlib, json, os, sys
version, notes, zip_path, out = sys.argv[1:]
with open(zip_path, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
manifest = {
    "version": version, "tag": f"v{version}", "notes": open(notes).read().strip(),
    "archives": {"AppleSilicon": {"name": os.path.basename(zip_path), "size": os.path.getsize(zip_path), "sha256": digest}},
}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
git -C "$ROOT" add updates/latest.json
git -C "$ROOT" commit -qm "Update manifest for $VERSION"
git -C "$ROOT" push -q
echo "    updates/latest.json → $VERSION"

echo "\n==> Updating the Homebrew cask"
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
tap="$BUILD/tap"
gh repo clone "$TAP_REPO" "$tap" -- --quiet --depth 1
sed -E -i '' \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \"[0-9a-f]*\"/  sha256 \"$sha\"/" \
  "$tap/Casks/velvet.rb"
grep -q "$sha" "$tap/Casks/velvet.rb" || { echo "Couldn't update $tap/Casks/velvet.rb" >&2; exit 1; }
git -C "$tap" commit -qam "Velvet $VERSION"
git -C "$tap" push -q
echo "    $TAP_REPO → $VERSION"
