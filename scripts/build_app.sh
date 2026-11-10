#!/usr/bin/env bash
#
# 把 SwiftPM 可执行文件打包成可双击运行的 .app
#
#   ./scripts/build_app.sh            # 当前架构，debug 关闭（release）
#   UNIVERSAL=1 ./scripts/build_app.sh  # arm64 + x86_64 通用二进制
#   CONFIG=debug ./scripts/build_app.sh
#
set -euo pipefail

APP_NAME="Matrix"
CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build -c $CONFIG ${ARCH_FLAGS[*]:-} ${UNIVERSAL:+}"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --disable-sandbox

BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

if [[ ! -f "$BIN" ]]; then
  echo "!! 找不到可执行文件: $BIN" >&2
  exit 1
fi

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 版本号：有 git tag 用 tag，否则用日期
if git describe --tags --abbrev=0 >/dev/null 2>&1; then
  VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')"
else
  VERSION="0.1.0"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

# ad-hoc 签名，本机可直接运行；分发到别人机器需要 Developer ID
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "!! codesign 失败（不影响本机开发运行）"

echo "==> 打包完成: $APP"
echo "    运行: open \"$APP\""
echo "    架构: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
