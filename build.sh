#!/bin/bash
# Builds FMChat.app from FMChat.swift. Run from the folder containing FMChat.swift.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p FMChat.app/Contents/MacOS
swiftc -parse-as-library -O FMChat.swift -o FMChat.app/Contents/MacOS/FMChat

cat > FMChat.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FMChat</string>
    <key>CFBundleIdentifier</key><string>local.fmchat</string>
    <key>CFBundleName</key><string>FMChat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - FMChat.app
echo "Built FMChat.app — launch with: open FMChat.app"

# Build the fm CLI (single-file executables must be named main.swift for top-level code)
mkdir -p "$HOME/.local/bin"
TMPDIR_FM=$(mktemp -d)
cp fm.swift "$TMPDIR_FM/main.swift"
swiftc -O "$TMPDIR_FM/main.swift" -o "$HOME/.local/bin/fm"
rm -rf "$TMPDIR_FM"
echo "Built fm CLI — installed to ~/.local/bin/fm (make sure ~/.local/bin is in your PATH)"
