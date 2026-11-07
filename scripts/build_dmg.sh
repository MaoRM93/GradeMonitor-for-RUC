#!/bin/bash
#
# 打包 DMG 安装镜像（带背景图 + 指向 Applications 的箭头）
#
# 用法：
#   ./scripts/build_dmg.sh <app 路径> <版本号> [输出路径]
#
# 例：
#   ./scripts/build_dmg.sh ~/Desktop/GradeMonitor.app 108.0.0.114
#
# 产物：~/Desktop/GradeMonitor_<版本号>_macOS_<架构>.dmg
#       例：GradeMonitor_108.0.0.114_macOS_arm64.dmg
#
# 命名规范（自 114 起生效）：Name_Version_System_Architecture.<ext>
#   - 分隔符为下划线，不是连字符
#   - 该文件名会被直接当作 GitHub Release 资产名，而客户端
#     UpdateVerifier.selectForAsset() 按【资产名严格相等】匹配签名清单，
#     所以产物名必须与上传时的资产名逐字符一致，不要事后改名。
#   - 签名时用本脚本打印的路径即可（basename 已是资产名）。
#
# 架构标识可用环境变量覆盖：
#   GM_ARCH=x86_64 ./scripts/build_dmg.sh ...
#   默认 arm64（与历史资产名保持一致；产物本身是 universal 二进制）。
#
# 窗口布局由一个隐藏的 .DS_Store 承载：Finder 第一次打开挂载的镜像时
# 就是"App 在左、Applications 在右、中间箭头"的样子，用户只需拖一次。
#
set -euo pipefail

APP_PATH="${1:?用法: build_dmg.sh <app路径> <版本号> [输出路径]}"
VERSION="${2:?缺少版本号}"
ARCH="${GM_ARCH:-arm64}"
OUT_PATH="${3:-$HOME/Desktop/GradeMonitor_${VERSION}_macOS_${ARCH}.dmg}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VOL_NAME="GradeMonitor"
# Finder 窗口的内容区尺寸必须与背景图一致（make_dmg_background.py 的输出尺寸）。
# 注意 Finder 的 window bounds 把标题栏也算在内，直接给 WIN_H 会裁掉背景底部一条。
WIN_W=600
WIN_H=400
TITLEBAR_H=28
ICON_SIZE=128
APP_X=150   # app 图标中心 x
APP_Y=200   # app 图标中心 y
DIR_X=450   # Applications 图标中心 x
DIR_Y=200

if [[ ! -d "$APP_PATH" ]]; then
  echo "错误：找不到 App：$APP_PATH" >&2
  exit 1
fi
APP_PATH="$(cd "$APP_PATH/.." && pwd)/$(basename "$APP_PATH")"
if [[ "$APP_PATH" != *.app ]]; then
  echo "错误：$APP_PATH 不是一个 .app 包" >&2
  exit 1
fi

echo "==> 校验 App 基本信息"
APP_NAME="$(basename "$APP_PATH" .app)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
echo "    App        : $APP_NAME"
echo "    BundleID   : $BUNDLE_ID"
echo "    版本        : $APP_VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist"))"

WORK_DIR="$(mktemp -d /tmp/gm-dmg.XXXXXX)"
STAGING="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/rw.dmg"
MOUNT_POINT="/Volumes/$VOL_NAME"

cleanup() {
  # 无论成功失败都卸载、删临时目录
  # 注意：本脚本挂载的卷名可能与历史残留同名，实际挂载点会被系统改名成
  # "GradeMonitor 1"，所以这里按本次镜像路径反查实际挂载点，并顺带清理同名残留卷。
  if [[ -n "${ACTUAL_MOUNT:-}" && -d "${ACTUAL_MOUNT:-}" ]]; then
    hdiutil detach "$ACTUAL_MOUNT" -force -quiet 2>/dev/null || true
  fi
  for d in "$MOUNT_POINT" "$MOUNT_POINT 1" "$MOUNT_POINT 2"; do
    if [[ -d "$d" ]]; then
      hdiutil detach "$d" -force -quiet 2>/dev/null || true
    fi
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 预清理：如果上次异常退出残留了同名卷（/Volumes/GradeMonitor），
# 新镜像会被挂载成 "GradeMonitor 1"，而脚本早期版本会误写只读的残留挂载点。
echo "==> 清理历史残留挂载卷"
for d in "$MOUNT_POINT" "$MOUNT_POINT 1" "$MOUNT_POINT 2"; do
  if [[ -d "$d" ]]; then
    echo "    卸载残留卷: $d"
    hdiutil detach "$d" -force -quiet 2>/dev/null || true
  fi
done

echo "==> 生成背景图"
BG_DIR="$WORK_DIR/background"
/usr/bin/python3 "$SCRIPT_DIR/make_dmg_background.py" "$BG_DIR"

echo "==> 构建暂存目录"
mkdir -p "$STAGING"
# 用 ditto 而不是 cp：macOS 上 ditto 能完整保留符号链接、扩展属性与签名
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

echo "==> 创建可读写中间镜像（$((WIN_W+40))x$((WIN_H+120)) 略大于窗口，避免滚动条）"
hdiutil create \
  -srcfolder "$STAGING" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

echo "==> 挂载中间镜像"
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen >/dev/null
# 挂载点可能被重命名（如 "GradeMonitor 1"），以实际为准
ACTUAL_MOUNT="$(hdiutil info | awk -v d="$RW_DMG" '
  $0 ~ d {found=1}
  found && /\/Volumes\// {for(i=1;i<=NF;i++) if($i ~ /^\/Volumes\//){print $i; exit}}
')"
if [[ -z "$ACTUAL_MOUNT" ]]; then
  ACTUAL_MOUNT="$MOUNT_POINT"
fi
echo "    挂载于: $ACTUAL_MOUNT"

echo "==> 写入背景图与卷图标"
mkdir -p "$ACTUAL_MOUNT/.background"
cp "$BG_DIR/background.png" "$ACTUAL_MOUNT/.background/background.png"
cp "$BG_DIR/background@2x.png" "$ACTUAL_MOUNT/.background/background@2x.png"
# 卷图标（挂载后在 Finder 侧边栏/Dock 里显示 App 图标）
ICNS="$PROJECT_ROOT/frontend/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon.icns"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$ACTUAL_MOUNT/.VolumeIcon.icns"
  SetFile -a C "$ACTUAL_MOUNT" || true
fi

echo "==> 用 Finder 写入窗口布局（图标位置 + 背景图）"
# 这一步需要终端拥有"自动化 → Finder"权限。若被系统弹窗拒绝，
# 镜像仍会生成，只是没有背景图和图标位置（退化为普通 DMG）。
osascript <<APPLESCRIPT || echo "    ⚠️  Finder 布局写入失败（缺少自动化权限），生成的是无背景 DMG"
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 200 + $WIN_W, 200 + $((WIN_H + TITLEBAR_H))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$DIR_X, $DIR_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

echo "==> 让 Finder 把 .DS_Store 落盘"
# Finder 是懒写入的：再打开一次并等待，避免 .DS_Store 没写完就转成只读
osascript -e "tell application \"Finder\" to open disk \"$VOL_NAME\"" >/dev/null 2>&1 || true
sleep 3
osascript -e "tell application \"Finder\" to close disk \"$VOL_NAME\"" >/dev/null 2>&1 || true
sync
sleep 1

if [[ ! -f "$ACTUAL_MOUNT/.DS_Store" ]]; then
  echo "    ⚠️  未生成 .DS_Store —— 镜像将没有自定义背景"
fi

echo "==> 卸载"
hdiutil detach "$ACTUAL_MOUNT" -force -quiet
sleep 1

echo "==> 压缩为最终 DMG"
rm -f "$OUT_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_PATH" >/dev/null

SIZE="$(stat -f%z "$OUT_PATH")"
SHA="$(shasum -a 256 "$OUT_PATH" | awk '{print $1}')"
OUT_NAME="$(basename "$OUT_PATH")"
EXPECT_NAME="GradeMonitor_${VERSION}_macOS_${ARCH}.dmg"

echo ""
echo "────────────────────────────────────────────────"
echo "✓ DMG 已生成: $OUT_PATH"
echo "  资产名  : $OUT_NAME"
echo "  体积    : $((SIZE / 1024 / 1024)) MB ($SIZE bytes)"
echo "  sha256  : $SHA"
echo "────────────────────────────────────────────────"
if [[ "$OUT_NAME" != "$EXPECT_NAME" ]]; then
  echo ""
  echo "⚠️  产物名不符合发布资产命名规范"
  echo "    实际: $OUT_NAME"
  echo "    期望: $EXPECT_NAME"
  echo "    上传 GitHub 时资产名必须与签名清单的 file= 逐字符一致，"
  echo "    否则客户端 selectForAsset() 匹配不到清单，自动安装会被拒绝。"
fi
echo ""
echo "下一步："
echo "  1) 验证    : open \"$OUT_PATH\""
echo "  2) 签名    : ./scripts/sign_release.sh \"$OUT_PATH\" macos $VERSION"
echo "              然后把清单块贴进 Release 正文（每个资产一块）"
echo "  3) 上传    : 资产名用 ${OUT_NAME}（不要改名）"
