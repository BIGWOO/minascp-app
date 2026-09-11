#!/bin/zsh
set -eu
cd "${0:A:h:h}"
: "${MINASCP_VERSION:?Set release version}"
: "${MINASCP_BUILD:?Set increasing build number}"
: "${MINASCP_PREVIOUS_BUILD:?Set previously published build number}"
: "${MINASCP_UPDATE_PUBLIC_KEY:?Set update public key}"
: "${MINASCP_RELEASE_NOTES:?Set Markdown release notes path}"
: "${MINASCP_SIGNING_ACCOUNT:?Set Sparkle Keychain account}"
[[ -s "$MINASCP_RELEASE_NOTES" ]] || { print -u2 'Release notes are missing or empty'; exit 1; }
export MINASCP_VERSION MINASCP_BUILD MINASCP_PREVIOUS_BUILD MINASCP_UPDATE_PUBLIC_KEY
python3 - <<'PY'
import os, re

def number(text):
    if not re.fullmatch(r'\d+(\.\d+){0,2}', text):
        raise SystemExit('Invalid build number')
    value = tuple(map(int, text.split('.')))
    return value + (0,) * (3 - len(value))
if number(os.environ['MINASCP_BUILD']) <= number(os.environ['MINASCP_PREVIOUS_BUILD']):
    raise SystemExit('Build number must increase beyond the last published build')
PY
swift package resolve
sparkle_tools=.build/artifacts/sparkle/Sparkle/bin
public_key=$("$sparkle_tools/generate_keys" --account "$MINASCP_SIGNING_ACCOUNT" -p)
[[ "$public_key" == "$MINASCP_UPDATE_PUBLIC_KEY" ]] || { print -u2 'Signing account does not match embedded public key'; exit 1; }
name="MinaSCP-${MINASCP_VERSION}-${MINASCP_BUILD}-universal"
[[ ! -e "dist/$name" ]] || { print -u2 'Release directory already exists; preserve it before rebuilding'; exit 1; }
./scripts/build-app.sh release
app=build/release/MinaSCP.app
mkdir -p dist
staging=$(mktemp -d build/package.XXXXXX)
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/assets" "$staging/dmg"
ditto "$app" "$staging/dmg/MinaSCP.app"
ln -s /Applications "$staging/dmg/Applications"
cp docs/INSTALL.md "$staging/dmg/安裝說明.md"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/assets/$name.zip"
python3 - "$MINASCP_RELEASE_NOTES" "$staging/RELEASE-BODY.md" <<'PYNOTES'
import datetime, os, pathlib, sys
source, destination = map(pathlib.Path, sys.argv[1:])
date = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
destination.write_text(f"版本：{os.environ['MINASCP_VERSION']} · 發佈日期：{date}\n\n" + source.read_text())
PYNOTES
cp "$staging/RELEASE-BODY.md" "$staging/assets/$name.md"
prefix="https://github.com/BIGWOO/minascp-app/releases/download/v${MINASCP_VERSION}/"
if [[ "${MINASCP_UPDATE_TEST:-0}" == 1 ]]; then
    prefix="${MINASCP_FEED_URL%/*}/"
fi
"$sparkle_tools/generate_appcast" --account "$MINASCP_SIGNING_ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "$prefix" --release-notes-url-prefix "$prefix" "$staging/assets"
python3 scripts/verify-appcast.py "$staging/assets/appcast.xml" "$MINASCP_BUILD" "$prefix" "$sparkle_tools" "$MINASCP_SIGNING_ACCOUNT"
# Add manual-install DMG only after appcast generation, so Sparkle uses the ZIP.
hdiutil create -volname "MinaSCP $MINASCP_VERSION" -srcfolder "$staging/dmg" -format UDZO "$staging/assets/$name.dmg"
mv "$staging/RELEASE-BODY.md" "$staging/assets/RELEASE-BODY.md"
(cd "$staging/assets" && shasum -a 256 "$name.zip" "$name.dmg" "$name.md" appcast.xml RELEASE-BODY.md > SHA256SUMS.txt)
mv "$staging/assets" "dist/$name"
print "Prepared (not published): dist/$name"
