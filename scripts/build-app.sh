#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
APP="$PWD/dist/Work Pager.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WorkPager "$APP/Contents/MacOS/WorkPager"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WorkPager</string>
<key>CFBundleIdentifier</key><string>local.WorkPager</string>
<key>CFBundleName</key><string>Work Pager</string>
<key>CFBundleDisplayName</key><string>Work Pager</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>選択した音声入力から通知音をローカル検出します。音声は外部送信しません。</string>
<key>NSCameraUsageDescription</key><string>在席・不在を端末内で判定してARMを切り替えます。画像は保存・送信しません。</string>
<key>NSCameraUseContinuityCameraDeviceType</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
