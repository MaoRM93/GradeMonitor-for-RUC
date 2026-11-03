#!/usr/bin/env bash
# 为发布包生成 Ed25519 签名清单（贴到 GitHub Release 正文里）
#
# 用法:
#   scripts/sign_release.sh <安装包路径> <macos|windows> <版本号>
#
# 示例:
#   scripts/sign_release.sh ~/Desktop/GradeMonitor-108.0.0.111-macOS-arm64.zip macos 108.0.0.111
#
# 依赖: openssl（macOS 自带 LibreSSL 即可）、shasum
#
# 私钥位置（不进仓库、不随包分发）:
#   ~/Library/Application Support/GradeMonitor-signing/release_private.pem
#
# 输出为一段可直接粘进 Release 正文的 ```text 围栏块。
# 客户端 UpdateVerifier 会从中解析本平台清单并用内置公钥验签；
# 验签或摘要不匹配时，自动安装会被拒绝（fail-closed）。

set -euo pipefail

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

KEY_DIR="$HOME/Library/Application Support/GradeMonitor-signing"
PRIVATE_KEY="$KEY_DIR/release_private.pem"
if [[ ! -f "$PRIVATE_KEY" ]]; then
  echo "错误: 找不到私钥 $PRIVATE_KEY" >&2
  echo "（私钥只应存在于开发机，绝不入库、绝不随包分发）" >&2
  exit 1
fi

BASENAME="$(basename "$FILE")"
SHA256="$(shasum -a 256 "$FILE" | cut -d' ' -f1)"

TMPDIR_SIGN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SIGN"' EXIT

PAYLOAD="$TMPDIR_SIGN/payload.txt"
SIG="$TMPDIR_SIGN/sig.bin"

# 被签名的原文：header + 各字段，行尾统一 \n（最后一行也带 \n）
{
  echo "gm-release-v1"
  echo "platform=$PLATFORM"
  echo "version=$VERSION"
  echo "file=$BASENAME"
  echo "sha256=$SHA256"
} > "$PAYLOAD"

openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$PAYLOAD" -out "$SIG"

SIG_LEN="$(wc -c < "$SIG" | tr -d ' ')"
if [[ "$SIG_LEN" != "64" ]]; then
  echo "错误: 签名为 $SIG_LEN 字节，应为 64 字节" >&2
  exit 1
fi

SIG_B64="$(base64 < "$SIG" | tr -d '\n')"

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
