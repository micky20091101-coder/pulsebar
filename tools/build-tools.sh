#!/bin/bash
# 一键重建所有开发辅助工具（源码在 tools/，产物在 build/）
# 这些工具只在开发/验证时用，不参与 App 打包，删了随时可以重建。
set -e
cd "$(dirname "$0")/.."
mkdir -p build
for f in tools/*.swift; do
  name="$(basename "$f" .swift)"
  [ "$name" = "build-tools" ] && continue
  printf "  %-14s" "$name"
  xcrun swiftc -O -swift-version 5 "$f" -o "build/$name" 2>/dev/null && echo "✅" || echo "⚠️ (跳过)"
done
echo "完成。产物在 build/"
