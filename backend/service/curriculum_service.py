"""按已登录账号年级解密并在本机浏览器展示培养方案。

年级来源有两套：
  - 账号匹配（grade_for_current_user）：用户名前 4 位即年级，403 语义保持不变；
  - 显式指定（open_curriculum(grade=...)）：只要该年级的培养方案文件真的
    存在（available_grades()）就放行，供开发者开关 1.1 解锁全部年级入口。
"""
import secrets
import time
import webbrowser
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import HTTPException
from fastapi.responses import Response
from backend.storage.flags import flag_enabled
from backend.storage.settings import load_settings

_KEY = b"SnShSAul5176K4h4hufxCrmSs7zUfvbo"
_ROOT = Path(__file__).resolve().parents[2]
_CURRICULA_DIR = _ROOT / "assets" / "curricula"
_OPEN_TOKENS: dict[str, tuple[str, float]] = {}
_TTL_SECONDS = 300


def grade_for_current_user() -> str:
    grade = str(load_settings().get("username", "")).strip()[:4]
    if grade not in {"2024", "2025", "2026"}:
        raise HTTPException(status_code=403, detail="当前登录账号未匹配可用培养方案")
    return grade


def available_grades() -> list[str]:
    """实际已部署的年级列表（升序）。

    以磁盘上的 `assets/curricula/*.pdf.enc` 为唯一事实来源：将来新增
    `2027.pdf.enc` 即自动出现在前端入口里，不需要改代码——这就是契约里
    所说的"预留增补接口"。
    """
    try:
        names = [p.name for p in _CURRICULA_DIR.iterdir() if p.is_file()]
    except OSError:
        return []
    grades = {n[:-8] for n in names if n.endswith(".pdf.enc") and len(n) > 8}
    return sorted(grades)


def _decrypt(grade: str) -> bytes:
    path = _CURRICULA_DIR / f"{grade}.pdf.enc"
    try:
        raw = path.read_bytes()
        if raw[:5] != b"GMCP1": raise ValueError("格式不受支持")
        return AESGCM(_KEY).decrypt(raw[5:17], raw[17:], grade.encode())
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="该年级培养方案尚未部署")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="培养方案解密失败")


def open_curriculum(grade: str | None = None) -> str:
    """打开培养方案。

    grade 为 None：沿用原逻辑，按当前登录账号的年级；
    grade 显式给出：仅当该年级的培养方案确实存在时放行，否则 403。
    """
    if grade is None:
        target = grade_for_current_user()
    else:
        target = str(grade).strip()
        if target not in available_grades():
            raise HTTPException(status_code=403, detail="该年级培养方案尚未部署")
    token = secrets.token_urlsafe(32)
    _OPEN_TOKENS[token] = (target, time.time() + _TTL_SECONDS)
    webbrowser.open(f"http://127.0.0.1:18923/api/curriculum/view/{target}?access={token}")
    return target


def view_curriculum(grade: str, access: str) -> Response:
    entry = _OPEN_TOKENS.pop(access, None)
    if entry is None or entry[0] != grade or entry[1] < time.time():
        raise HTTPException(status_code=403, detail="访问链接已失效")
    # 开发者开关 1.1 开启时不再要求"账号年级 == 目标年级"；关闭时行为与原来
    # 完全一致（grade_for_current_user 的 403 语义保持不变）。
    if not flag_enabled("Enable_PYFA_EvyGrde") and grade != grade_for_current_user():
        raise HTTPException(status_code=403, detail="账号年级不匹配")
    return Response(_decrypt(grade), media_type="application/pdf", headers={"Content-Disposition": "inline"})
