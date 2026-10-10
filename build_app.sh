#!/bin/bash
# 构建 池塘金鱼.app：swift build -c release → 组装 .app 包 → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="池塘金鱼"
EXEC_NAME="PondGoldfish"
BUNDLE_ID="com.yiner.pondgoldfish"
VERSION="0.0.2"   # 唯一版本号来源（CFBundleShortVersionString）；代码里 swift run 时回退到 AppInfo.fallbackVersion
BUILD_NUMBER="2"   # CFBundleVersion

if ! command -v swift >/dev/null 2>&1; then
  echo "❌ 没找到 swift。请先安装 Xcode，或在终端运行：xcode-select --install" >&2
  exit 1
fi

echo "▶︎ 编译 (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/${APP_NAME}.app"
echo "▶︎ 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>池塘金鱼 · 个人学习用途</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶︎ ad-hoc 签名"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s - "$APP"
codesign --verify --verbose=1 "$APP" || true

echo
echo "✅ 完成：$(pwd)/$APP"
echo "   运行：open \"$APP\"   （或拖到「应用程序」文件夹后双击）"
