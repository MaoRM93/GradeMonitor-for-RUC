#!/usr/bin/env bash
#
# 发布一条**已签名**的远程通知（蓝屏 / 红屏 / 普通广播 / 114 号段关停）。
#
# 为什么要有这个脚本：
#   客户端原先内置一个「控制台」卡片，能直接调 GitHub API 发布 Release。
#   那意味着任何能进开发者面板的人都拿到了仓库写权限的入口，而且令牌
#   得经过客户端——一旦客户端被改，令牌就跟着泄了。
#   现在把发布搬出客户端：客户端只**读** Release（匿名，不需要令牌），
#   写入只在本机终端里用私钥签名 + 令牌发布。客户端因此不持有任何
#   能写仓库的东西。
#
# 客户端会怎么校验：
#   1. 正文里必须有一个 ```text 围栏块，首行 `gm-notice-v1`
#   2. 块内 kind= 必须与该通道期望值一致（red/blue/broadcast/disable114）
#   3. 块内 tag= 必须等于实际 Release tag
#   4. sig= 必须是内置公钥能验证的 64 字节 Ed25519 签名
#   5. 块内 sha256= 必须等于「去掉签名块之后的正文」的 SHA-256
#   任何一条不满足，客户端就把这条通知当作不存在（不会弹屏、也不会
#   把已经生效的停用状态误清除）。
#
# 用法：
#   scripts/publish_notice.sh <kind> [选项]
#
#   kind: red | blue | broadcast | disable114
#
#   通用选项：
#     -t, --title TEXT       Release 标题（默认取 tag）
#     -b, --body TEXT        通知正文；不传则从 stdin 读
#     -f, --body-file FILE   从文件读正文（优先于 --body）
#     -r, --tag TAG          覆盖 tag（仅 broadcast 需要，默认 114.<时间戳>）
#     -n, --dry-run          只打印签名块，不发布
#         --delete           删除该通道对应的 Release（撤回）
#     -h, --help             显示帮助
#
#   环境变量：
#     GITHUB_TOKEN   必填（发布/删除时需要）。需要该仓库的 Releases 写权限。
#                    建议用 `gh auth token` 或一个仅限本仓库的 classic PAT。
#
# 例子：
#   # 发布一条蓝屏提醒
#   GITHUB_TOKEN=xxx scripts/publish_notice.sh blue -t "维护通知" -b "今晚 23:00 起维护。"
#
#   # 发一条普通广播，先看看签名块长什么样
#   scripts/publish_notice.sh broadcast -b "新版本已发布。" --dry-run
#
#   # 撤回红屏（解除全局停用）
#   GITHUB_TOKEN=xxx scripts/publish_notice.sh red --delete
#
set -euo pipefail

REPO="MaoRM93/GradeMonitor-for-RUC"
API="https://api.github.com/repos/${REPO}/releases"
NOTICE_HEADER="gm-notice-v1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 各通道的固定 tag；broadcast 的 tag 由用户给或自动生成
tag_for_kind() {
  case "$1" in
    red)        echo "service-suspension" ;;
    blue)       echo "developer-alert" ;;
    disable114) echo "114.512" ;;
    broadcast)  echo "" ;;
    *)          echo "未知通道：$1" >&2; exit 2 ;;
  esac
}

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

KIND=""
TITLE=""
BODY=""
BODY_FILE=""
TAG=""
DRY_RUN=0
DELETE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    red|blue|broadcast|disable114) KIND="$1"; shift ;;
    -t|--title)      TITLE="${2:-}"; shift 2 ;;
    -b|--body)       BODY="${2:-}"; shift 2 ;;
    -f|--body-file)  BODY_FILE="${2:-}"; shift 2 ;;
    -r|--tag)        TAG="${2:-}"; shift 2 ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    --delete)        DELETE=1; shift ;;
    -h|--help)       usage ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[[ -n "$KIND" ]] || { echo "缺少通道参数（red / blue / broadcast / disable114）" >&2; exit 2; }

DEFAULT_TAG="$(tag_for_kind "$KIND")"
if [[ -z "$TAG" ]]; then
  if [[ "$KIND" == "broadcast" ]]; then
    TAG="114.$(date +%s)"
  else
    TAG="$DEFAULT_TAG"
  fi
fi

if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" ]] || { echo "正文文件不存在：$BODY_FILE" >&2; exit 2; }
  BODY="$(cat "$BODY_FILE")"
elif [[ -z "$BODY" && "$DELETE" -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    BODY="$(cat)"
  fi
fi

[[ -n "$TITLE" ]] || TITLE="$TAG"

if [[ "$DELETE" -eq 1 ]]; then
  [[ -n "${GITHUB_TOKEN:-}" ]] || { echo "删除需要 GITHUB_TOKEN" >&2; exit 2; }
  echo "撤回 tag=${TAG} …"
  ID="$(curl -sS -H "Accept: application/vnd.github+json" \
             -H "Authorization: Bearer ${GITHUB_TOKEN}" \
             "${API}/tags/${TAG}" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id",""))' 2>/dev/null || true)"
  if [[ -z "$ID" ]]; then
    echo "该 tag 不存在，无需撤回"
    exit 0
  fi
  curl -sS -X DELETE -H "Accept: application/vnd.github+json" \
       -H "Authorization: Bearer ${GITHUB_TOKEN}" \
       "${API}/${ID}" > /dev/null
  echo "已撤回 ${TAG}"
  exit 0
fi

[[ -n "$BODY" ]] || { echo "正文为空：用 -b / -f 或从 stdin 传入" >&2; exit 2; }

# ---- 组装被签名的原文 ----
#
# 顺序固定：header → kind → tag → sha256。sha256 算的是正文（去掉签名块），
# 因此正文改了签名就对不上；tag 写进签名，因此签名块不能被搬到别的 tag 上。
#
# 注意：客户端算摘要时走的是「先剥掉签名块、再去掉首尾空白行」，所以这里
# 必须用同一套规范化，否则正文首尾多一个换行就会导致两边摘要不一致。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if grep -qF "$NOTICE_HEADER" <<< "$BODY"; then
  echo "正文里不能出现 ${NOTICE_HEADER}：那会被客户端当成签名块剥掉" >&2
  exit 2
fi

printf '%s' "$BODY" > "$TMP/body"
# 规范化：折叠连续空行、去掉首尾空白行 —— 与客户端 stripNoticeBlocks 完全一致，
# 这样「算摘要用的正文」和「实际发布出去的正文」是同一串字节。
BODY="$(/usr/bin/python3 - "$TMP/body" <<'PY'
import sys
raw = open(sys.argv[1], encoding="utf-8").read()
out = []
for line in raw.split("\n"):
    if line.strip() == "" and out and out[-1].strip() == "":
        continue
    out.append(line)
while out and out[0].strip() == "":
    out.pop(0)
while out and out[-1].strip() == "":
    out.pop()
sys.stdout.write("\n".join(out))
PY
)"
SHA="$(printf '%s' "$BODY" | shasum -a 256 | cut -d' ' -f1)"

{
  echo "$NOTICE_HEADER"
  echo "kind=$KIND"
  echo "tag=$TAG"
  echo "sha256=$SHA"
} > "$TMP/payload"

SIG_B64="$(cd "$ROOT_DIR" && python3 - "$TMP/payload" <<'PY'
import base64, sys
from backend.storage.signing_keys import release_private_key
payload = open(sys.argv[1], 'rb').read()
sig = release_private_key().sign(payload)
if len(sig) != 64:
    raise SystemExit(f'签名长度异常：{len(sig)}')
print(base64.b64encode(sig).decode('ascii'))
PY
)"

{
  echo '```text'
  cat "$TMP/payload"
  echo "sig=$SIG_B64"
  echo '```'
} > "$TMP/block"

BLOCK="$(cat "$TMP/block")"
FULL_BODY="${BODY}

${BLOCK}"

echo "── 通道：${KIND}"
echo "── tag ：${TAG}"
echo "── sha256：${SHA}"
echo "── 签名块："
echo "$BLOCK"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "（--dry-run：未发布）"
  exit 0
fi

[[ -n "${GITHUB_TOKEN:-}" ]] || { echo "发布需要 GITHUB_TOKEN" >&2; exit 2; }

# ---- 发布：已存在则 PATCH，否则 POST ----
/usr/bin/python3 - "$TAG" "$TITLE" "$FULL_BODY" <<'PY'
import json, os, sys, urllib.request

tag, title, body = sys.argv[1], sys.argv[2], sys.argv[3]
repo = "MaoRM93/GradeMonitor-for-RUC"
api = f"https://api.github.com/repos/{repo}/releases"
token = os.environ["GITHUB_TOKEN"]
headers = {
    "Accept": "application/vnd.github+json",
    "Authorization": f"Bearer {token}",
    "X-GitHub-Api-Version": "2022-11-28",
}

def call(url, method="GET", payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, json.loads(resp.read() or b"{}")

try:
    status, existing = call(f"{api}/tags/{tag}")
except urllib.error.HTTPError as e:
    if e.code != 404:
        raise
    status, existing = 404, {}

payload = {"tag_name": tag, "name": title, "body": body,
           "draft": False, "prerelease": True}

if status == 200 and existing.get("id"):
    code, _ = call(f"{api}/{existing['id']}", method="PATCH", payload=payload)
    print(f"已更新 Release {tag}（HTTP {code}）")
else:
    code, _ = call(api, method="POST", payload=payload)
    print(f"已创建 Release {tag}（HTTP {code}）")
PY

echo
echo "客户端会在下一次远程检查（启动时 + 每小时）生效。"
