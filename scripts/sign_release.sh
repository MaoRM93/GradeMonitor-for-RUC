#!/usr/bin/env bash
# 为发布包生成 Ed25519 签名清单（贴到 GitHub Release 正文里）
#
# 用法:
#   scripts/sign_release.sh <安装包路径> <macos|windows> <版本号>
#
# 示例:
#   scripts/sign_release.sh ~/Desktop/GradeMonitor_108.0.0.114_macOS_arm64.dmg macos 108.0.0.114
#   scripts/sign_release.sh ~/Desktop/GradeMonitor_108.0.0.114_Windows_x64.zip windows 108.0.0.114
#
# 资产命名规范（自 114 起）：Name_Version_System_Architecture.<ext>
#   - 分隔符是下划线，不是连字符
#   - Windows 包不再带 -Setup
#   - **本脚本用「文件名的 basename」作为清单的 file= 字段**，而客户端
#     UpdateVerifier.selectForAsset() 按资产名严格相等匹配。因此传入的文件
#     必须已经是上传到 GitHub 时用的资产名，不要传临时名或本地别名。
#
# 依赖: openssl（macOS 自带 LibreSSL 即可）、shasum
#
# 私钥位置：开发机 macOS 钥匙串（不进仓库、不随包分发、不写入临时文件）。
#
# 输出为一段可直接粘进 Release 正文的 ```text 围栏块。
# 客户端 UpdateVerifier 会从中解析本平台清单并用内置公钥验签；
# 验签或摘要不匹配时，自动安装会被拒绝（fail-closed）。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
SIGNING_PYTHON="${GM_SIGNING_PYTHON:-python3}"

if [[ $# -ne 3 ]]; then
  echo "用法: $0 <安装包路径> <macos|windows> <版本号>" >&2
  exit 1
fi

FILE="$1"
PLATFORM="$2"
VERSION="$3"

if [[ ! -f "$FILE" ]]; then
  echo "错误: 找不到文件 $FILE" >&2
  exit 1
fi
if [[ "$PLATFORM" != "macos" && "$PLATFORM" != "windows" ]]; then
  echo "错误: 平台必须是 macos 或 windows，收到 '$PLATFORM'" >&2
  exit 1
fi

BASENAME="$(basename "$FILE")"
SHA256="$(shasum -a 256 "$FILE" | cut -d' ' -f1)"

TMPDIR_SIGN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SIGN"' EXIT

PAYLOAD="$TMPDIR_SIGN/payload.txt"

# 被签名的原文：header + 各字段，行尾统一 \n（最后一行也带 \n）
{
  echo "gm-release-v1"
  echo "platform=$PLATFORM"
  echo "version=$VERSION"
  echo "file=$BASENAME"
  echo "sha256=$SHA256"
} > "$PAYLOAD"

SIG_B64="$("$SIGNING_PYTHON" - "$PAYLOAD" <<'PY'
import base64, sys
from backend.storage.signing_keys import release_private_key
payload = open(sys.argv[1], 'rb').read()
sig = release_private_key().sign(payload)
if len(sig) != 64:
    raise SystemExit(f'签名长度异常：{len(sig)}')
print(base64.b64encode(sig).decode('ascii'))
PY
)"
SIG_LEN="64"

echo "────────────────────────────────────────────────"
echo "文件     : $BASENAME"
echo "平台     : $PLATFORM"
echo "版本     : $VERSION"
echo "SHA-256  : $SHA256"
echo "签名长度 : $SIG_LEN 字节"
echo "────────────────────────────────────────────────"
echo "把下面整段（含围栏）贴进 Release 正文："
echo
echo '```text'
cat "$PAYLOAD"
echo "sig=$SIG_B64"
echo '```'
