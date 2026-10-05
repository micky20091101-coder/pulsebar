#!/bin/bash
# PulseBar 构建脚本（无需 Xcode，只需 Command Line Tools）
# 用法: ./build.sh            # 构建到 build/PulseBar.app
#       ./build.sh --install  # 构建后安装到 ~/Applications 并启动
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/PulseBar.app"
NAME="PulseBar"

echo "==> 清理旧的构建产物"
/bin/rm -rf "$BUILD/$NAME.app" "$BUILD/$NAME" "$BUILD/AppIcon.iconset"

echo "==> 编译图标工具并生成图标"
mkdir -p "$BUILD"
xcrun swiftc -O -swift-version 5 tools/makeicon.swift -o "$BUILD/makeicon"
"$BUILD/makeicon" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

echo "==> 编译主程序"
xcrun swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
  -framework UserNotifications \
  Sources/*.swift -o "$BUILD/$NAME"

echo "==> 组装 .app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(签名跳过)"

echo "==> 完成: $APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> 安装到 ~/Applications"
  /bin/rm -rf "$HOME/Applications/$NAME.app"
  cp -R "$APP" "$HOME/Applications/$NAME.app"
  codesign --force --deep --sign - "$HOME/Applications/$NAME.app" >/dev/null 2>&1 || true
  echo "==> 启动"
  open "$HOME/Applications/$NAME.app"
  echo "已安装并启动: ~/Applications/$NAME.app"
fi
