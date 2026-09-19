#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'The .app bundles must be built on macOS.' >&2; exit 1; }
args=(-c release)
if [[ ${USERBOX_UNIVERSAL:-0} == 1 ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
bin=$(swift build "${args[@]}" --show-bin-path)
mkdir -p dist
bundle() {
    local product=$1 identifier=$2 ui=$3
    local root="dist/$product.app"
    mkdir -p "$root/Contents/MacOS"
    cp "$bin/$product" "$root/Contents/MacOS/$product"
    cat > "$root/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>$product</string>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><$ui/>
</dict></plist>
PLIST
    plutil -lint "$root/Contents/Info.plist"
    codesign --force --sign - --identifier "$identifier" "$root"
    codesign --verify --strict "$root"
}
bundle UserBox io.userbox.viewer false
bundle UserBoxSession io.userbox.session true
cp "$bin/userboxctl" dist/userboxctl
cp scripts/prepare.sh scripts/uninstall.sh dist/
cp docs/macos-demo.md dist/SETUP.md
cat > 'dist/Start UserBox.command' <<'LAUNCH'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo 'This creates one dedicated standard account and installs the desktop demo. It does not enable network screen sharing or change TCC.'
sudo /bin/bash ./prepare.sh demo
open /Applications/UserBox.app
LAUNCH
chmod +x dist/*.sh 'dist/Start UserBox.command' dist/userboxctl
printf '\nBuilt native bundles in %s/dist\n' "$PWD"
