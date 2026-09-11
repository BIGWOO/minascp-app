#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build
mkdir -p build/MinaSCP.app/Contents/MacOS
cp .build/debug/MinaSCP build/MinaSCP.app/Contents/MacOS/MinaSCP
cp .build/debug/MinaSCPAskPass build/MinaSCP.app/Contents/MacOS/MinaSCPAskPass
codesign --force --sign - build/MinaSCP.app/Contents/MacOS/MinaSCPAskPass
cat > build/MinaSCP.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>MinaSCP</string><key>CFBundleIdentifier</key><string>com.mina.scp</string><key>CFBundleName</key><string>MinaSCP</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.4.0</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - build/MinaSCP.app
