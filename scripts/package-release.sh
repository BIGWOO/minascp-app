#!/bin/zsh
set -eu
cd "${0:A:h:h}"
./scripts/build-app.sh release
app=build/release/MinaSCP.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
name="MinaSCP-${version}-${number}-universal"
mkdir -p dist
[[ ! -e "dist/$name.zip" && ! -e "dist/$name.dmg" ]] || { print -u2 'Release artifacts already exist; preserve or relocate them before rebuilding.'; exit 1; }
staging=$(mktemp -d build/dmg.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/MinaSCP.app"
ln -s /Applications "$staging/Applications"
cp docs/INSTALL.md "$staging/安裝說明.md"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$name.zip"
hdiutil create -volname "MinaSCP $version" -srcfolder "$staging" -ov -format UDZO "dist/$name.dmg"
(cd dist && shasum -a 256 "$name.zip" "$name.dmg" > SHA256SUMS.txt)
print "Packaged: dist/$name.dmg and dist/$name.zip"
