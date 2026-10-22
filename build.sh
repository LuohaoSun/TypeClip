#!/bin/zsh
# 构建并签名 TypeClip.app(只需 Xcode Command Line Tools)
#
#   ./build.sh           开发构建: 带测试钩子(--notify-drive / --notify-keydiag / --drive-once / --selfcheck)
#   ./build.sh release   发布构建: 编掉全部测试钩子, 可以发给同事
#
# 两者都固定 -target arm64-apple-macosx13.0:
# 不指定 target 时 swiftc 会拿编译机的系统版本当最低版本(本机 macOS 27 → minos 27.0),
# 那样的包别人打不开, 而且 Info.plist 里的 LSMinimumSystemVersion 拦不住它——
# Mach-O 的 load command 才是被强制的那个。MenuBarExtra / SMAppService 都是 macOS 13 起可用。
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-dev}"
if [[ "$MODE" != "dev" && "$MODE" != "release" ]]; then
  echo "用法: ./build.sh [dev|release]" >&2
  exit 2
fi

DEPLOY_TARGET="arm64-apple-macosx13.0"
SOURCES=(
  Sources/TypeClipApp.swift
  Sources/TyperEngine.swift
  Sources/Keymap.swift
  Sources/HotkeyCenter.swift
  Sources/TypeLog.swift
)

FLAGS=(-O -swift-version 5 -target "$DEPLOY_TARGET")
# 两种模式输出到不同目录, 免得发一次版就把本机在用的开发构建覆盖掉。
if [[ "$MODE" == "dev" ]]; then
  FLAGS+=(-D TYPECLIP_DEV_HOOKS)
  # KeyDiag 是纯诊断模块, 本身就会去 post com.slh.typeclip.drive 通知,
  # 只被 dev 钩子调用 —— 发布构建里干脆不编译它, 否则那串通知名会留在二进制里。
  SOURCES+=(Sources/KeyDiag.swift)
  OUT=build
else
  OUT=build/release
fi

mkdir -p "$OUT"
echo "== swiftc ($MODE, $DEPLOY_TARGET) =="
swiftc "${FLAGS[@]}" "${SOURCES[@]}" -o "$OUT/TypeClip"

APP="$OUT/TypeClip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/TypeClip" "$APP/Contents/MacOS/TypeClip"
cp Support/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "== codesign =="
codesign --force --sign - "$APP"

echo "== 校验 =="
lipo -info "$OUT/TypeClip" | sed 's/^/  /'
vtool -show-build "$OUT/TypeClip" | grep -E "minos|platform" | sed 's/^/  /'
if [[ "$MODE" == "release" ]]; then
  # 钩子痕迹必须从二进制里彻底消失, 否则编译期开关就没生效。
  # 只查"能当入口用"的串: 通知名与命令行开关。
  # (TypeLog 里那个 "TypeClip-keydiag.log" 只是文件名, 不构成入口, 不算。)
  LEAKED=0
  for pat in "com.slh.typeclip.drive" "com.slh.typeclip.keydiag" \
             "--notify-drive" "--notify-keydiag" "--drive-once" "--keydiag" "--selfcheck"; do
    if strings "$OUT/TypeClip" | grep -qF -e "$pat"; then
      echo "  ❌ 发布构建里仍存在测试钩子入口: $pat"
      LEAKED=1
    fi
  done
  if (( LEAKED )); then
    echo "    别分发这个包。"
    exit 1
  fi
  echo "  ✓ 二进制中已无测试钩子入口(通知名与命令行开关均已编掉)"
fi

echo "== done =="
echo "$PWD/$APP"
if [[ "$MODE" == "dev" ]]; then
  echo "⚠️  开发构建: 含测试钩子, 任何本机进程都能经分布式通知驱动它敲键盘。"
  echo "    要发给别人请用 ./build.sh release"
else
  echo "✅ 发布构建: 测试钩子已编掉, 可分发。"
fi
