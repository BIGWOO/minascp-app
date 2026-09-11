#!/bin/zsh
set -eu
cd "${0:A:h:h}"
configuration="${1:-debug}"
[[ "$configuration" == debug || "$configuration" == release ]] || { print -u2 'Usage: build-app.sh [debug|release]'; exit 1; }
# Unsigned developer builds remain usable; release builds must carry a valid update key.
export MINASCP_VERSION="${MINASCP_VERSION:-1.1.0}"
export MINASCP_BUILD="${MINASCP_BUILD:-260911.1}"
export MINASCP_FEED_URL="${MINASCP_FEED_URL:-https://github.com/BIGWOO/minascp-app/releases/latest/download/appcast.xml}"
export MINASCP_UPDATE_PUBLIC_KEY="${MINASCP_UPDATE_PUBLIC_KEY:-}"
export MINASCP_UPDATE_TEST="${MINASCP_UPDATE_TEST:-0}"
python3 scripts/update-config.py validate "$configuration"
build_args=(-c "$configuration")
if [[ "$configuration" == release ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
mkdir -p "build/$configuration"
staging=$(mktemp -d "build/$configuration/staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/MinaSCP.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$staging/AppIcon.iconset"
cp "$bin_dir/MinaSCP" "$bin_dir/MinaSCPAskPass" "$app/Contents/MacOS/"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$staging/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" Assets/AppIcon.png --out "$staging/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$staging/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MinaSCP</string>
<key>CFBundleIdentifier</key><string>com.mina.scp</string>
<key>CFBundleName</key><string>MinaSCP</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 scripts/update-config.py plist "$app/Contents/Info.plist"
framework=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
mkdir -p "$app/Contents/Frameworks"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE"
# Preserve Sparkle's upstream nested signatures. Ad-hoc signing the enclosing app
# does not require replacing the framework's Developer ID signatures.
codesign --verify --deep --strict "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app/Contents/MacOS/MinaSCPAskPass"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ -d "build/$configuration/MinaSCP.app" ]]; then
    mv "build/$configuration/MinaSCP.app" "build/$configuration/MinaSCP-previous-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$app" "build/$configuration/MinaSCP.app"
print "Built: build/$configuration/MinaSCP.app"
