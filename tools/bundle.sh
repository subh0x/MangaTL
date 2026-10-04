#!/bin/zsh
# Builds MangaTL.app from the Swift package: tools/bundle.sh [debug|release]
set -e
cd "${0:A:h}/.."
config=${1:-release}
swift build -c $config --product MangaTL ${=SWIFT_FLAGS}
bin=$(swift build -c $config ${=SWIFT_FLAGS} --show-bin-path)
app=MangaTL.app
rm -rf $app && mkdir -p $app/Contents/{MacOS,Resources}
cp $bin/MangaTL $app/Contents/MacOS/
cp -R $bin/*.bundle $app/Contents/Resources/ 2>/dev/null || true
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.mangatl</string>
  <key>CFBundleName</key><string>MangaTL</string>
  <key>CFBundleExecutable</key><string>MangaTL</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSEnvironment</key><dict><key>MallocSpaceEfficient</key><string>1</string></dict>
</dict></plist>
PLIST
codesign -s - --force $app >/dev/null
echo "built $app ($config)"
