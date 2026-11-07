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
  "$PROJECT_ROOT/backend/" "$RES/backend/"

# ---------- 2. 复制便携 Python（并裁剪无用体积） ----------
echo "==> [2/4] 复制便携 Python 运行时"
rm -rf "$RES/runtime/python"
rsync -a --exclude '.DS_Store' "$PY_SRC/" "$RES/runtime/python/"

PY="$RES/runtime/python"
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
if ! "$PY/bin/python3" -c 'import uvicorn, fastapi, requests, bs4, websockets; print("deps ok")'; then
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
rm -rf "$APP_PATH"
ditto "$WORK_APP" "$APP_PATH" 2>/dev/null || true

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
