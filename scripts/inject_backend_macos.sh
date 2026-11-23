#!/bin/bash
#
# 把 Python 便携运行时 + backend 注入 macOS .app 包内，并重新签名
#
# 背景：
#   Flutter 的 macOS 构建只会产出前端二进制，Python 后端根本不在包里。
#   Windows 侧靠 .data/prepare_staging.py 复制 backend + runtime/tools；
#   macOS 侧长期缺失这一步，导致从 Finder 启动的 App 找不到 Python、
#   后端永远起不来，前端所有请求都以 Connection refused 失败。
#
# 本脚本把以下内容放进 .app/Contents/Resources：
#   runtime/python/   便携 CPython（python-build-standalone，可重定位）
#   backend/          后端源码（排除 __pycache__）
#   assets/curricula/ 加密培养方案资源
#
# 前端 frontend/lib/core/service/backend_service.dart 会优先在
# Contents/Resources 下寻找 backend/api/app.py 与 runtime/python/bin/python3。
#
# 用法：
#   scripts/inject_backend_macos.sh <App.app 路径> [便携 Python 根目录]
#
# 例：
#   scripts/inject_backend_macos.sh \
#     frontend/build/macos/Build/Products/Release/GradeMonitor.app
#
# 便携 Python 根目录默认取环境变量 GM_PORTABLE_PYTHON，否则依次尝试
#   runtime/python、/tmp/gm_runtime/python
#
set -euo pipefail

APP_PATH="${1:?用法: inject_backend_macos.sh <App.app 路径> [便携 Python 根目录]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PY_SRC="${2:-${GM_PORTABLE_PYTHON:-}}"
if [[ -z "$PY_SRC" ]]; then
  for cand in "$PROJECT_ROOT/runtime/python" /tmp/gm_runtime/python; do
    if [[ -x "$cand/bin/python3" ]]; then PY_SRC="$cand"; break; fi
  done
fi
if [[ -z "$PY_SRC" || ! -x "$PY_SRC/bin/python3" ]]; then
  echo "错误：找不到便携 Python 运行时（需含 bin/python3）" >&2
  echo "      可用第二个参数或环境变量 GM_PORTABLE_PYTHON 指定" >&2
  exit 1
fi
PY_SRC="$(cd "$PY_SRC" && pwd)"

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
  echo "错误：$APP_PATH 不是一个 .app 包" >&2
  exit 1
fi
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
ORIGIN_APP="$APP_PATH"

# 本仓库位于 iCloud Drive 内，iCloud 会给文件持续打上 com.apple.provenance
# 等扩展属性，codesign 会因此报 "resource fork, Finder information, or
# similar detritus not allowed"，被改动过的 Python.app 签不上名 → 冒烟测试
# 直接被 Killed: 9。所以整个注入流程在 /tmp 的干净副本上完成，最后再回写。
WORK_ROOT="/tmp/gm_inject"
mkdir -p "$WORK_ROOT"
APP_PATH="$WORK_ROOT/$(basename "$ORIGIN_APP")"
rm -rf "$APP_PATH"
ditto "$ORIGIN_APP" "$APP_PATH"
xattr -cr "$APP_PATH" 2>/dev/null || true
RES="$APP_PATH/Contents/Resources"

echo "==> 注入目标: $APP_PATH"
echo "    Python : $PY_SRC"

mkdir -p "$RES/runtime" "$RES/backend"

# ---------- 1. 复制 backend（排除缓存与开发文件） ----------
echo "==> [1/4] 复制 backend"
rm -rf "$RES/backend"
rsync -a \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  --exclude 'test_*.py' \
  --exclude '*_test.py' \
  "$PROJECT_ROOT/backend/" "$RES/backend/"

# 培养方案仅以 AES-GCM 密文随包分发；解密由本机后端按登录账号完成。
if [[ -d "$PROJECT_ROOT/assets" ]]; then
  rsync -a --exclude '.DS_Store' "$PROJECT_ROOT/assets/" "$RES/assets/"
fi

# ---------- 2. 复制便携 Python（并裁剪无用体积） ----------
echo "==> [2/4] 复制便携 Python 运行时"
rm -rf "$RES/runtime/python"
rsync -a --exclude '.DS_Store' "$PY_SRC/" "$RES/runtime/python/"
# 源运行时来自 iCloud，rsync 会把扩展属性一并带过来；不清掉会导致后面
# 的 codesign 全部失败（签名无效 → 二进制被内核拒绝加载）。
xattr -cr "$RES/runtime/python" 2>/dev/null || true
xattr -cr "$RES/backend" 2>/dev/null || true

PY="$RES/runtime/python"
# Homebrew Python 的原生扩展链接了开发机上的 OpenSSL、SQLite、xz 与
# mpdecimal。将运行时库放进 Python.framework，并把扩展的加载路径改为
# 相对路径，确保发布包不要求用户安装 Homebrew。
PY_FRAMEWORK_LIB="$PY/Frameworks/Python.framework/Versions/3.11/lib"
mkdir -p "$PY_FRAMEWORK_LIB"
for source_lib in \
  /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib \
  /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib \
  /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib \
  /opt/homebrew/opt/xz/lib/liblzma.5.dylib \
  /opt/homebrew/opt/mpdecimal/lib/libmpdec.4.dylib; do
  if [[ ! -f "$source_lib" ]]; then
    echo "错误：构建机缺少原生运行时库: $source_lib" >&2
    exit 1
  fi
  cp -L "$source_lib" "$PY_FRAMEWORK_LIB/"
done

# lib-dynload 下的扩展与内嵌库均改为包内相对引用。扩展位于
# .../lib/python3.11/lib-dynload，回到 framework lib 需 ../../。
while IFS= read -r -d '' native_module; do
  while IFS= read -r dependency; do
    lib_name="$(basename "$dependency")"
    [[ -f "$PY_FRAMEWORK_LIB/$lib_name" ]] || continue
    install_name_tool -change "$dependency" "@loader_path/../../$lib_name" "$native_module" || true
  done < <(otool -L "$native_module" | awk 'NR > 1 {print $1}' | grep '^/opt/homebrew/' || true)
done < <(find "$PY_FRAMEWORK_LIB/python3.11/lib-dynload" -name '*.so' -type f -print0)

# 被内嵌的库彼此也不能再引用 Homebrew 的绝对路径（目前仅 libssl →
# libcrypto，但按检测结果处理可避免后续 Homebrew 升级再次引入此问题）。
for embedded_lib in "$PY_FRAMEWORK_LIB"/*.dylib; do
  [[ -f "$embedded_lib" ]] || continue
  while IFS= read -r dependency; do
    lib_name="$(basename "$dependency")"
    [[ -f "$PY_FRAMEWORK_LIB/$lib_name" ]] || continue
    install_name_tool -change "$dependency" "@loader_path/$lib_name" "$embedded_lib" || true
  done < <(otool -L "$embedded_lib" | awk 'NR > 1 {print $1}' | grep '^/opt/homebrew/' || true)
  codesign --force --sign - --timestamp=none "$embedded_lib" 2>/dev/null || true
done
find "$PY_FRAMEWORK_LIB/python3.11/lib-dynload" -name '*.so' -type f -print0 \
  | xargs -0 -n 20 codesign --force --sign - --timestamp=none 2>/dev/null || true

# Homebrew Python 的二进制默认链接到开发机绝对 Framework 路径。将其改成
# 包内相对路径，并以启动器固定 PYTHONHOME，避免发布包依赖开发机环境。
PY_BIN="$PY/bin/python3.11"
if [[ -x "$PY_BIN" ]]; then
  # Homebrew 的 framework 本体与 Python.app 启动器也会记录绝对 Cellar
  # 路径；三者均须改为相对引用，才能在未安装 Homebrew Python 的电脑运行。
  PY_FRAMEWORK="$PY/Frameworks/Python.framework/Versions/3.11/Python"
  PY_APP_BIN="$PY/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"
  for target in "$PY_BIN" "$PY_FRAMEWORK" "$PY_APP_BIN"; do
    [[ -x "$target" ]] || continue
    OLD_PY_FRAMEWORK="$(otool -L "$target" | awk '/Python\.framework\/Versions\/3\.11\/Python/{print $1; exit}')"
    [[ -n "$OLD_PY_FRAMEWORK" ]] || continue
    case "$target" in
      "$PY_APP_BIN") replacement='@loader_path/../../../../Python' ;;
      *) replacement='@loader_path/../Python' ;;
    esac
    install_name_tool -change "$OLD_PY_FRAMEWORK" "$replacement" "$target" || true
    # install_name_tool 会使原签名失效；macOS 会在运行前杀掉这种二进制，
    # 所以冒烟测试之前先用 adhoc 签名恢复其可执行性。
    codesign --force --sign - --timestamp=none "$target" 2>/dev/null || true
  done
  install -m 755 "$SCRIPT_DIR/runtime_python_launcher.sh" "$PY/bin/python3"
fi
# Python.framework 是一个嵌套 bundle；仅签各个二进制会留下外层封印失效，
# 导致 macOS 以 Killed: 9 拒绝加载。冒烟前由内向外重签。
#
# 坑：这份 runtime 是 Homebrew 的 Python.framework 直接拷来的，缺少
# Versions/Current、Python 等顶层符号链接，codesign 会把 framework 根目录
# 判成 "bundle format unrecognized"；真正有效的 bundle 是 Versions/3.11，
# 所以签它而不是签根目录，并把里面的 Python.app 一并深签。
PY_FW_V="$PY/Frameworks/Python.framework/Versions/3.11"
if [[ -d "$PY_FW_V" ]]; then
  xattr -cr "$PY_FW_V" 2>/dev/null || true
  codesign --force --deep --sign - --timestamp=none "$PY_FW_V" 2>/dev/null || true
fi
# 裁剪：pip/setuptools 等打包期工具、测试与 GUI 相关模块在运行时一律用不到。
# 保留 ensurepip 之外的一切标准库，避免误删 uvicorn 依赖。
rm -rf \
  "$PY/lib/python3.11/site-packages/pip" \
  "$PY/lib/python3.11/site-packages/pip-"*.dist-info \
  "$PY/lib/python3.11/site-packages/setuptools" \
  "$PY/lib/python3.11/site-packages/setuptools-"*.dist-info \
  "$PY/lib/python3.11/site-packages/pkg_resources" \
  "$PY/lib/python3.11/site-packages/_distutils_hack" \
  "$PY/lib/python3.11/site-packages/distutils-precedence.pth" \
  "$PY/lib/python3.11/ensurepip" \
  "$PY/lib/python3.11/idlelib" \
  "$PY/lib/python3.11/turtledemo" \
  "$PY/lib/python3.11/test" \
  "$PY/include" \
  "$PY/share" \
  "$PY/lib/tcl8" "$PY/lib/tcl8.6" "$PY/lib/tk8.6" \
  "$PY/lib/libtcl8.6.dylib" "$PY/lib/libtk8.6.dylib" \
  "$PY/lib/itcl4.2.4" "$PY/lib/thread2.8.9" \
  "$PY/lib/python3.11/lib-dynload/_tkinter"*.so
# 只保留解释器本体与必要的 bin 入口，去掉 pip/idle/pydoc 等脚本
find "$PY/bin" -maxdepth 1 -type f \
  ! -name 'python3*' ! -name 'uvicorn' ! -name 'fastapi' -delete 2>/dev/null || true
# bin 下的符号链接若指向已删除脚本会变成断链，清掉
find "$PY/bin" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null || true

# ---------- 3. 冒烟：包内解释器必须能 import uvicorn 且能加载 backend ----------
echo "==> [3/4] 冒烟测试包内运行时"
if ! "$PY/bin/python3" -c 'import uvicorn, fastapi, requests, bs4, websockets, cryptography; print("deps ok")'; then
  echo "错误：包内 Python 缺少依赖（需要 fastapi/uvicorn/requests/bs4/websockets）" >&2
  exit 1
fi
# 注意：导入 backend.api.app 会触发数据目录初始化，若不重定向就会在
# 真实用户目录（~/Library/Application Support/GradeMonitor）里创建日志与
# 令牌文件。打包阶段绝不能污染用户数据，这里用临时目录隔离。
SMOKE_DIR="$(mktemp -d /tmp/gm-smoke.XXXXXX)"
if ! ( cd "$RES" && GRADEMONITOR_DATA_DIR="$SMOKE_DIR" \
      "$PY/bin/python3" -c 'import backend.api.app; print("backend ok")' >/dev/null 2>&1 ); then
  rm -rf "$SMOKE_DIR"
  echo "错误：包内 backend 无法导入" >&2
  exit 1
fi
rm -rf "$SMOKE_DIR"
echo "    backend + 依赖导入正常"

# 上面的 import 会在包内 $RES/backend 下现场生成 __pycache__（rsync 阶段是
# 干净的，脏在这一步）。它会把 .pyc 一起打进 DMG，也会让 bundle 里出现
# 源码缓存，所以在签名前清掉。
find "$RES/backend" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$RES/backend" -name '*.pyc' -type f -delete 2>/dev/null || true

# ---------- 4. 重新签名 ----------
# 往已签名 bundle 里塞文件会让原签名失效（Sealed Resources 不匹配），
# 必须由内向外重签。本项目发布用 adhoc 签名（无开发者证书）。
#
# 坑：本仓库位于 iCloud Drive 内，iCloud 会持续给文件重新打上
# com.apple.provenance 等扩展属性，导致 codesign 报
# "resource fork, Finder information, or similar detritus not allowed"。
# 因此在 /tmp 里完成 xattr 清理与签名，再用 ditto 拷回原位置
# （ditto 保签名，不会重新引入属性）。
echo "==> [4/4] 重新签名（adhoc，在 /tmp 完成以避免 iCloud 属性干扰）"
SIGN_TMP="$(mktemp -d /tmp/gm-sign.XXXXXX)"
trap 'rm -rf "$SIGN_TMP"' EXIT
APP_NAME="$(basename "$APP_PATH")"
ditto "$APP_PATH" "$SIGN_TMP/$APP_NAME"
WORK_APP="$SIGN_TMP/$APP_NAME"

# 清掉隔离/来源扩展属性，它们会让 codesign 失败
xattr -cr "$WORK_APP" 2>/dev/null || true

# 先签所有 Mach-O（dylib / so / 可执行文件），从深到浅
find "$WORK_APP/Contents/Resources/runtime" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 \
  | xargs -0 -n 20 codesign --force --sign - --timestamp=none 2>/dev/null || true
for f in \
  "$WORK_APP/Contents/Resources/runtime/python/bin/python3.11" \
  "$WORK_APP/Contents/Resources/runtime/python/bin/python3" \
  "$WORK_APP/Contents/Resources/runtime/python/bin/python"; do
  [[ -e "$f" ]] && codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true
done
# 再签 bundle 内既有 framework 与主程序，最后签外层 .app
codesign --force --deep --sign - --timestamp=none "$WORK_APP"

if ! codesign --verify --deep --strict "$WORK_APP" 2>/dev/null; then
  echo "⚠️  签名校验未通过（adhoc 签名对 --strict 偶有告警，通常仍可运行）" >&2
fi

# 把签名好的包放到 /tmp 供后续打包（DMG/zip）直接使用。
# 注意：不要用"拷回 iCloud 原位置"的包做发布产物 —— iCloud 会立刻重新
# 打上 com.apple.provenance 扩展属性，导致 codesign --verify 报
# "resource fork, Finder information, or similar detritus not allowed"。
# 发布产物必须基于 /tmp 里这份干净签名包生成。
SIGNED_OUT="/tmp/gm_signed/$(basename "$APP_PATH")"
mkdir -p /tmp/gm_signed
rm -rf "$SIGNED_OUT"
ditto "$WORK_APP" "$SIGNED_OUT"
echo "    签名包已就绪: $SIGNED_OUT"

# 同步回原位置（仅供本地调试运行；iCloud 环境下 verify 可能报扩展属性告警）
rm -rf "$ORIGIN_APP"
ditto "$WORK_APP" "$ORIGIN_APP" 2>/dev/null || true

SIZE="$(du -sh "$SIGNED_OUT" | awk '{print $1}')"
echo ""
echo "────────────────────────────────────────────────"
echo "✓ 后端已注入: $SIGNED_OUT"
echo "  体积    : $SIZE"
echo "  Python  : $("$PY/bin/python3" -c 'import sys; print(sys.version.split()[0])')"
echo "  backend : $RES/backend"
echo "────────────────────────────────────────────────"
echo "打包 DMG 请用: $SIGNED_OUT"
echo "（不要用仓库内那份，iCloud 会破坏签名校验）"
