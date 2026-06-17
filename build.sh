#!/bin/bash
# 把 codex-cc-pet.swift 编译成通用二进制(arm64 + x86_64)放进 codex-cc-pet.app。
# 仅在改了源码、需要重建时跑;产物 .app 可直接拷到别的 Mac 双击运行,无需在目标机编译。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/codex-cc-pet.swift"
OUT="$DIR/codex-cc-pet.app/Contents/MacOS/codex-cc-pet"
mkdir -p "$(dirname "$OUT")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swiftc -O -target arm64-apple-macos12 "$SRC" -o "$tmp/arm64"
if swiftc -O -target x86_64-apple-macos12 "$SRC" -o "$tmp/x86_64" 2>/dev/null; then
  lipo -create "$tmp/arm64" "$tmp/x86_64" -o "$OUT"
  echo "✅ 通用二进制(arm64 + x86_64),Intel 与 Apple Silicon 都能跑"
else
  cp "$tmp/arm64" "$OUT"
  echo "⚠️ x86_64 跨编译不可用,仅出 arm64(Apple Silicon 机器可用)"
fi
chmod +x "$OUT"
lipo -info "$OUT"

# --- 生成 app 图标(make-icon.swift → iconset → AppIcon.icns)---
RES="$DIR/codex-cc-pet.app/Contents/Resources"
mkdir -p "$RES"
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
swiftc -O "$DIR/make-icon.swift" -o "$tmp/makeicon"
"$tmp/makeicon" "$iconset" >/dev/null
iconutil -c icns "$iconset" -o "$RES/AppIcon.icns"
echo "✅ 图标 AppIcon.icns 已生成"
