#!/bin/bash
# 编译并组装 AppDim.app（本地免费小工具，ad-hoc 签名）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src/main.swift"
APP="$ROOT/AppDim.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== 编译 =="
swiftc -O -o "$APP/Contents/MacOS/AppDim" "$SRC" -framework Cocoa -framework Carbon -framework ServiceManagement

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# 图标
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/icon/AppDim.icns" "$APP/Contents/Resources/" 2>/dev/null || true

echo "== ad-hoc 签名 =="
codesign --force --sign - "$APP"

echo "== 完成: $APP =="
