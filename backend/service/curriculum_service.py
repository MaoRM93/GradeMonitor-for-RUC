"""按已登录账号年级解密并在本机浏览器展示培养方案。"""
import secrets
import time
import webbrowser
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import HTTPException
from fastapi.responses import Response
from backend.storage.settings import load_settings

_KEY = b"SnShSAul5176K4h4hufxCrmSs7zUfvbo"
_ROOT = Path(__file__).resolve().parents[2]
_OPEN_TOKENS: dict[str, tuple[str, float]] = {}
_TTL_SECONDS = 300

def grade_for_current_user() -> str:
    grade = str(load_settings().get("username", "")).strip()[:4]
    if grade not in {"2024", "2025", "2026"}:
        raise HTTPException(status_code=403, detail="当前登录账号未匹配可用培养方案")
    return grade

def _decrypt(grade: str) -> bytes:
    path = _ROOT / "assets" / "curricula" / f"{grade}.pdf.enc"
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

def open_curriculum() -> str:
    grade = grade_for_current_user()
    token = secrets.token_urlsafe(32)
    _OPEN_TOKENS[token] = (grade, time.time() + _TTL_SECONDS)
    webbrowser.open(f"http://127.0.0.1:18923/api/curriculum/view/{grade}?access={token}")
    return grade

def view_curriculum(grade: str, access: str) -> Response:
    entry = _OPEN_TOKENS.pop(access, None)
    if entry is None or entry[0] != grade or entry[1] < time.time():
        raise HTTPException(status_code=403, detail="访问链接已失效")
    if grade != grade_for_current_user():
        raise HTTPException(status_code=403, detail="账号年级不匹配")
    return Response(_decrypt(grade), media_type="application/pdf", headers={"Content-Disposition": "inline"})
