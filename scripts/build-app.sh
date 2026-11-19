#!/usr/bin/env bash
# Builds "Task Manager.app" as a universal binary (Apple silicon + Intel),
# signs it ad hoc and packages a .zip and a .dmg into dist/.
#
#   scripts/build-app.sh                 # universal
#   ARCHS=arm64 scripts/build-app.sh     # one architecture
#   VERSION=1.2.0 scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64 x86_64}"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "==> Building Task Manager $VERSION ($BUILD) for: $ARCHS"
swift build -c release "${arch_flags[@]}"
bin_dir="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

app="dist/Task Manager.app"
rm -rf dist
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/TaskManager" "$app/Contents/MacOS/TaskManager"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

echo "==> Architectures"
lipo -info "$app/Contents/MacOS/TaskManager"

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"

suffix="universal"
[ "$(echo $ARCHS | wc -w | tr -d ' ')" = "1" ] && suffix="$ARCHS"

echo "==> Packaging"
ditto -c -k --keepParent "$app" "dist/TaskManager-$VERSION-$suffix.zip"
staging="$(mktemp -d)"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Task Manager" -srcfolder "$staging" -ov -format UDZO "dist/TaskManager-$VERSION-$suffix.dmg" >/dev/null
rm -rf "$staging"

(cd dist && shasum -a 256 *.zip *.dmg > SHA256SUMS)
cat dist/SHA256SUMS
