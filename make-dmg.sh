#!/bin/zsh
# 打一个带拖拽引导的 DMG: 把 TypeClip.app 和「应用程序」快捷方式并排放好, 中间一个箭头。
#
#   ./make-dmg.sh
#
# 产物: build/release/TypeClip-<版本>.dmg
# 依赖: 只用系统自带的 hdiutil / osascript / codesign / swiftc, 不需要 create-dmg。
#
# 两点说明:
#  - 窗口布局(图标坐标/背景图/窗口大小)靠 Finder 脚本写进卷里的 .DS_Store,
#    所以**执行时 Finder 必须能响应自动化**(终端或宿主 app 需要有"自动化 → Finder"权限)。
#  - 背景图是现画的(Support/make-dmg-background.swift), 图上除了箭头还写着两个同事
#    最容易卡住的信息: 未公证包首次要右键「打开」, 以及本包只支持 Apple 芯片。
set -euo pipefail
cd "$(dirname "$0")"

VOLNAME="${VOLNAME:-TypeClip}"   # 可用环境变量覆盖, 方便另起一个卷名做对照实验
MP="/Volumes/$VOLNAME"
RW_DMG="build/dmg-rw.dmg"
BG_PNG="build/dmg-background.png"
BG_TOOL="build/make-dmg-background"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
OUT="${OUT:-build/release/TypeClip-$VERSION.dmg}"

# 窗口与图标布局(单位: 点)。改这里的话记得同步改背景图里箭头的位置。
WIN_W=900
WIN_H=430
WIN_X=220
WIN_Y=160
APP_X=125;  APP_Y=220   # TypeClip.app 的图标位置(自内容区左上角计)
DEST_X=405; DEST_Y=220  # 「应用程序」快捷方式的位置

echo "== 1/6 发布构建 =="
./build.sh release

echo "== 2/6 生成引导背景图 =="
swiftc -O Support/make-dmg-background.swift -o "$BG_TOOL"
"$BG_TOOL" "$BG_PNG" $WIN_W $WIN_H 2

echo "== 3/6 建可写 DMG =="
# 万一上次的卷还挂着(异常中断), 先踢掉, 否则 Finder 脚本会挑错卷。
hdiutil detach "$MP" -force >/dev/null 2>&1 || true
rm -f "$RW_DMG"
mkdir -p build/release
hdiutil create -size 64m -fs HFS+ -volname "$VOLNAME" -ov "$RW_DMG" >/dev/null

# 必须挂到 /Volumes 下: 用自定义挂载点时 Finder 不把这个卷算进它的 disk 集合,
# 后面 `tell disk "TypeClip"` 会报 -1728, 图标位置就写不进 .DS_Store。
cleanup() { hdiutil detach "$MP" -force >/dev/null 2>&1 || true }
trap cleanup EXIT

hdiutil attach "$RW_DMG" -noverify -noautoopen >/dev/null
[ -d "$MP" ] || { echo "挂载失败: 没看到 $MP" >&2; exit 1; }

cp -R build/release/TypeClip.app "$MP/TypeClip.app"
ln -s /Applications "$MP/Applications"
mkdir -p "$MP/.background"
cp "$BG_PNG" "$MP/.background/bg.png"

echo "== 4/6 让 Finder 摆好图标与背景 =="
# 位置/视图偏好只能由 Finder 落在 .DS_Store 里, 所以这步必须走 AppleScript。
# 注意: 下面这个 heredoc 是**不加引号**的(要插值卷名与坐标), 所以 AppleScript 注释和
# 字符串里不要出现反引号或 $, 否则会被 shell 先当成命令替换/变量展开 —— 踩过一次。
osascript <<APPLESCRIPT
tell application "Finder"
  set vol to disk "$VOLNAME"
  -- 必须 make new Finder window: 直接取 container window 会抓到用户当前那个 Finder 窗口
  -- (当卷以它的标签页形式打开时), 那样既会把用户的窗口挪走, 也读不到真实内容区尺寸。
  set w to make new Finder window to vol
  delay 1
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set the bounds of w to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
  set vo to the icon view options of w
  set arrangement of vo to not arranged
  set icon size of vo to 128
  -- HFS 路径要带卷名, 才会相对这个卷解析; 只写 ".background:bg.png" 会解到启动盘根目录
  -- (报 sandbox_extension_issue_file failed for /.background/bg.png)。
  try
    set background picture of vo to file "$VOLNAME:.background:bg.png"
  end try
  set position of item "TypeClip.app" of vol to {$APP_X, $APP_Y}
  -- 指向 /Applications 的符号链接: Finder 里显示成「应用程序」, on-disk 名字是 Applications。
  -- 按 on-disk 名试, 失败就用排除法兜底(这个卷里除 .app 只剩它)。
  try
    set position of item "Applications" of vol to {$DEST_X, $DEST_Y}
  on error
    repeat with itm in (items of vol)
      if name of itm is not "TypeClip.app" then set position of itm to {$DEST_X, $DEST_Y}
    end repeat
  end try
  -- 没用 update without registering applications: macOS 26 的 Finder 对窗口执行它会报
  -- -10010(处理程序不能处理这个类的对象), 而位置/背景在 close 时本来就会写进 .DS_Store。
  delay 2
  close w
end tell
APPLESCRIPT

# 回读一次: 这些值只存在于 .DS_Store 里, 写不进去不会报错, 只会静默退化成默认排布,
# 所以必须显式核对, 否则要等同事打开 DMG 才发现引导图错位。
LAYOUT=$(osascript <<APPLESCRIPT
tell application "Finder" to tell disk "$VOLNAME"
  set a to position of item "TypeClip.app"
  set b to position of item "Applications"
  return ((item 1 of a) as string) & "," & ((item 2 of a) as string) & ";" & ((item 1 of b) as string) & "," & ((item 2 of b) as string)
end tell
APPLESCRIPT
) || LAYOUT=""
EXPECT="$APP_X,$APP_Y;$DEST_X,$DEST_Y"
if [ "$LAYOUT" = "$EXPECT" ]; then
  echo "  图标位置核对通过: $LAYOUT"
else
  echo "  ❌ 图标位置不符合预期(期望 $EXPECT, 实际 ${LAYOUT:-读取失败})" >&2
  exit 1
fi

echo "== 5/6 压缩成只读 DMG =="
sync
sleep 1
hdiutil detach "$MP" >/dev/null
trap - EXIT
rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW_DMG"

echo "== 6/6 签名并自检 =="
codesign --force --sign - "$OUT"
codesign --verify --verbose=1 "$OUT" 2>&1 | sed 's/^/  /'

hdiutil attach "$OUT" -noverify -noautoopen >/dev/null
trap cleanup EXIT
echo "  --- 卷内容 ---"
ls -1 "$MP" | sed 's/^/    /'
printf "    应用程序快捷方式 → %s\n" "$(readlink "$MP/Applications")"
printf "    布局文件 .DS_Store: %s\n" "$([ -f "$MP/.DS_Store" ] && echo 有 || echo '缺失(图标会落在默认位置)')"
printf "    背景图: %s\n" "$([ -f "$MP/.background/bg.png" ] && echo 有 || echo 缺失)"
printf "    最低系统版本: %s\n" "$(vtool -show-build "$MP/TypeClip.app/Contents/MacOS/TypeClip" | awk '/minos/{print $2}')"
hdiutil detach "$MP" >/dev/null
trap - EXIT

echo "== done =="
echo "$PWD/$OUT"
