# backend/storage/remote_gates.py
"""远程功能组开关下发：用 GitHub Release 当指令总线。

## 为什么复用 Release

客户端本来就每小时拉一次 `GET /repos/{repo}/releases`（`update_service.dart`
的 `checkReleaseNotices`），读 Release 是**匿名**的，不需要任何令牌。写 Release
需要仓库写权限——那条边界已经存在，不需要新建服务端。

## 号段与格式

使用独立的 `control-v<rev>` 频道，`rev` 单调递增。正文里放一个围栏块：

```text
gm-gates-v1
rev=7
issued_at=2026-11-16T00:00:00Z
Flag-1010=false
Flag-1066=false
sig=<base64 Ed25519 分离签名>
```

被签名的原文是 `sig=` 那一行之前的全部内容（含末尾换行），UTF-8 编码。
签名用开发机钥匙串中的**专用控制私钥**；控制公钥内置于客户端后端。

## 三道防线

1. **验签**：`sig` 必须能通过内置公钥验证。没有私钥的人即使拿到仓库写权限
   也签不出有效指令。
2. **rev 单调**：只接受 `rev` 严格大于本地已应用值的包。这样即使有人删除
   某个 `control-v` 发布，客户端也不会退回旧状态。
3. **只覆盖它显式列出的键**：远程值写在 `feature_gates_remote.json`，与本地
   `feature_gates.json` 分离；`effective = remote ?? local ?? True`。远程"开"
   不会顶掉用户自己关掉的东西（除非远程明确提到那个键）。

## 拉不到时的行为

**保持现状**，既不是全开也不是全关。断网、限流、验签失败、结构异常——一律
沿用上一次成功应用的值（或本地值）。绝不能因为"没拉到配置"就把功能全关掉，
那比远程关不掉严重得多。
"""
import base64
import json
import os
import re
from typing import Optional

import requests

from backend.storage.cache import atomic_write_json, get_data_file_path
from backend.storage.feature_gates import DEFAULT_GATES, load_gates
from backend.utils.logger import get_logger

logger = get_logger(__name__)

REMOTE_FILE = get_data_file_path("feature_gates_remote.json")

# 控制通道独立信任根；绝不能复用安装包/通知的发布签名密钥。
PUBLIC_KEY_B64 = "6/as6xSRMN4yVd+Fj7dnnMvfYVet/BnU3ONf6JCJ74c="

# 控制频道与 app-v* 更新频道严格分离；不能让控制发布被版本比较误认为更新。
TAG_PREFIX = "control-v"

SCHEMA = "gm-gates-v1"

_RELEASES_API = (
    "https://api.github.com/repos/MaoRM93/GradeMonitor-for-RUC/releases?per_page=50"
)
_TIMEOUT = 15

# 匹配 ```text ... ``` 围栏块
_FENCE_RE = re.compile(r"```[a-zA-Z]*\n(.*?)```", re.DOTALL)


# ------------------------------------------------------------------ 本地缓存

def load_remote() -> dict:
    """读取已应用的远程覆盖。返回 `{"rev": int, "gates": {id: bool}}`。"""
    if not os.path.exists(REMOTE_FILE):
        return {"rev": 0, "gates": {}}
    try:
        with open(REMOTE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        logger.warning(f"读取 feature_gates_remote.json 失败，按无覆盖处理: {e}")
        return {"rev": 0, "gates": {}}

    if not isinstance(data, dict):
        return {"rev": 0, "gates": {}}

    raw_gates = data.get("gates")
    gates: dict[str, bool] = {}
    if isinstance(raw_gates, dict):
        for gid, value in raw_gates.items():
            # 只保留当前版本注册表里存在的编号：旧版收到新编号应静默忽略
            if isinstance(gid, str) and gid in DEFAULT_GATES and isinstance(value, bool):
                gates[gid] = value

    try:
        rev = int(data.get("rev") or 0)
    except (TypeError, ValueError):
        rev = 0
    return {"rev": max(rev, 0), "gates": gates}


def save_remote(rev: int, gates: dict[str, bool]) -> dict:
    """写入一份完整的远程覆盖快照。只保留注册表内的键。"""
    clean = {
        gid: value
        for gid, value in (gates or {}).items()
        if gid in DEFAULT_GATES and isinstance(value, bool)
    }
    payload = {"rev": int(rev), "gates": clean}
    atomic_write_json(REMOTE_FILE, payload)
    logger.info(f"远程开关已应用：rev={rev}，{len(clean)} 项覆盖")
    return payload


def merge_remote(rev: int, gates: dict[str, bool]) -> dict:
    """把一条增量指令合并进当前远程覆盖。

    每条远程指令只带本次变动的 Flag；不能因为发布 Flag-A 而遗失此前
    Flag-B 的覆盖。空字典明确表示撤销全部远程覆盖。
    """
    if not gates:
        return save_remote(rev, {})
    current = load_remote()
    merged = dict(current["gates"])
    for gid, value in gates.items():
        if gid in DEFAULT_GATES and isinstance(value, bool):
            merged[gid] = value
    return save_remote(rev, merged)


# ------------------------------------------------------------------ 生效值

def effective_gates() -> dict:
    """本地值叠加远程覆盖后的最终开关表。

    `remote ?? local ?? True`：远程只管它显式列出的键。
    """
    merged = load_gates()
    remote = load_remote()
    for gid, value in remote["gates"].items():
        if gid in merged:
            merged[gid] = value
    return merged


# ------------------------------------------------------------------ 验签

def _public_key(public_key_b64: str):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    raw = base64.b64decode(public_key_b64)
    if len(raw) != 32:
        raise ValueError("内置公钥长度异常（应为 32 字节）")
    return Ed25519PublicKey.from_public_bytes(raw)


def verify_block(block: str) -> Optional[tuple[int, dict[str, bool]]]:
    """验证一个围栏块。成功返回 `(rev, gates)`，任何异常都返回 None。"""
    lines = block.strip("\n").split("\n")
    if not lines or lines[0].strip() != SCHEMA:
        return None

    sig_index = None
    for i, line in enumerate(lines):
        if line.startswith("sig="):
            sig_index = i
            break
    if sig_index is None or sig_index == 0:
        logger.warning("远程开关块缺少 sig，整包丢弃")
        return None

    payload = "\n".join(lines[:sig_index]) + "\n"
    sig_b64 = lines[sig_index][len("sig="):].strip()

    try:
        from cryptography.exceptions import InvalidSignature

        sig = base64.b64decode(sig_b64)
        if len(sig) != 64:
            logger.warning("远程开关签名长度异常，整包丢弃")
            return None
        _public_key(PUBLIC_KEY_B64).verify(sig, payload.encode("utf-8"))
    except InvalidSignature:
        logger.warning("远程开关签名不匹配，整包丢弃")
        return None
    except Exception as e:
        logger.warning(f"远程开关验签异常，整包丢弃: {e}")
        return None

    rev: Optional[int] = None
    gates: dict[str, bool] = {}
    for line in lines[1:sig_index]:
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if key == "rev":
            try:
                rev = int(value)
            except ValueError:
                return None
        elif key in DEFAULT_GATES:
            if value.lower() == "true":
                gates[key] = True
            elif value.lower() == "false":
                gates[key] = False

    if rev is None or rev <= 0:
        return None
    return rev, gates


# ------------------------------------------------------------------ 联网刷新

def refresh() -> dict:
    """从 GitHub 拉取最新的 `control-v*` 指令并应用。

    返回 `{"applied": bool, "rev": int, "reason": str}`。任何失败都不抛异常
    ——调用方是定时器，不该被网络问题打断。
    """
    current = load_remote()
    try:
        r = requests.get(
            _RELEASES_API,
            headers={
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            timeout=_TIMEOUT,
        )
    except requests.RequestException as e:
        logger.info(f"拉取远程开关失败（网络）：{e}")
        return {"applied": False, "rev": current["rev"], "reason": "network"}

    if not r.ok:
        logger.info(f"拉取远程开关失败（HTTP {r.status_code}）")
        return {"applied": False, "rev": current["rev"], "reason": "http"}

    try:
        releases = r.json()
    except ValueError:
        return {"applied": False, "rev": current["rev"], "reason": "json"}
    if not isinstance(releases, list):
        return {"applied": False, "rev": current["rev"], "reason": "shape"}

    # 收集所有号段内的包，按 rev 取最大
    best: Optional[tuple[int, dict[str, bool]]] = None
    for item in releases:
        if not isinstance(item, dict):
            continue
        tag = str(item.get("tag_name") or "")
        if not tag.startswith(TAG_PREFIX):
            continue
        body = str(item.get("body") or "")
        for block in _FENCE_RE.findall(body):
            parsed = verify_block(block)
            if parsed is None:
                continue
            if best is None or parsed[0] > best[0]:
                best = parsed

    if best is None:
        logger.info("远程开关：未发现有效指令包")
        return {"applied": False, "rev": current["rev"], "reason": "none"}

    rev, gates = best
    if rev <= current["rev"]:
        # 回滚防护：只接受严格更大的 rev
        logger.info(f"远程开关：rev={rev} 不大于已应用的 {current['rev']}，忽略")
        return {"applied": False, "rev": current["rev"], "reason": "stale"}

    # 每个 Release 块是完整快照；直接覆盖，确保首次获取的客户端完整同步。
    save_remote(rev, gates)
    return {"applied": True, "rev": rev, "reason": "ok"}


# ------------------------------------------------------------------ 签发

def _block_with_key(rev: int, gates: dict[str, bool], issued_at: str, key) -> str:
    """使用给定私钥构造同一格式的签名块。"""
    lines = [SCHEMA, f"rev={rev}", f"issued_at={issued_at}"]
    for gid in sorted(gates):
        if gid in DEFAULT_GATES:
            lines.append(f"{gid}={'true' if gates[gid] else 'false'}")
    payload = "\n".join(lines) + "\n"
    sig = key.sign(payload.encode("utf-8"))
    if len(sig) != 64:
        raise ValueError(f"签名长度为 {len(sig)} 字节，应为 64 字节")
    return f"```text\n{payload}sig={base64.b64encode(sig).decode('ascii')}\n```"


def build_block(rev: int, gates: dict[str, bool], issued_at: str) -> str:
    """构造由专用控制密钥签发的围栏块。"""
    from backend.storage.signing_keys import control_private_key
    return _block_with_key(rev, gates, issued_at, control_private_key())


