# backend/auth/session_store.py
"""登录会话持久化（把 cookie 加密落盘，供监控循环与静默续期复用）

设计要点：
  · 只存 cookie，不存密码明文（密码仍由 storage/credentials.py 走钥匙串/DPAPI）。
  · 落盘前用与凭据模块同一档的加密：macOS 走钥匙串存 JSON 串、Windows 走 DPAPI、
    其它平台退化为 0600 文件 + base64。
  · 读失败一律返回 None，绝不抛异常打断 App 启动。
  · jw `token` 只有 12 小时，所以启动时必须先判断是否还有效；无效时
    用 CAS 的 CASTGC 静默续期（见 cas_login.silent_renew）。

文件：<数据目录>/session.json（密文）
"""
import base64
import json
import os
import subprocess
import sys
from typing import Optional

from backend.utils.logger import get_logger

logger = get_logger(__name__)

SESSION_FILE_NAME = "session.json"
KEYCHAIN_SERVICE = "GradeMonitor"
KEYCHAIN_ACCOUNT = "session-cookies"

_CACHE: Optional[dict] = None
_LOADED = False


def _data_file(name: str) -> str:
    from backend.storage.cache import get_data_file_path

    return get_data_file_path(name)


# ---------------------------------------------------------------- 加解密

def _mac_encrypt(plain: str) -> bool:
    """macOS：写进登录钥匙串"""
    try:
        subprocess.run(
            [
                "security",
                "delete-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
            ],
            capture_output=True,
            timeout=10,
        )
        r = subprocess.run(
            [
                "security",
                "add-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
                plain,
                "-U",
            ],
            capture_output=True,
            timeout=10,
        )
        return r.returncode == 0
    except Exception as e:
        logger.warning(f"写钥匙串失败: {e}")
        return False


def _mac_decrypt() -> Optional[str]:
    try:
        r = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            capture_output=True,
            timeout=10,
        )
        if r.returncode != 0:
            return None
        return r.stdout.decode("utf-8", "replace").strip() or None
    except Exception:
        return None


def _dpapi_encrypt(plain: str) -> Optional[bytes]:
    try:
        import win32crypt  # type: ignore

        return win32crypt.CryptProtectData(plain.encode("utf-8"), None, None, None, None, 0)
    except Exception:
        return None


def _dpapi_decrypt(blob: bytes) -> Optional[str]:
    try:
        import win32crypt  # type: ignore

        return win32crypt.CryptUnprotectData(blob, None, None, None, 0)[1].decode("utf-8")
    except Exception:
        return None


# ---------------------------------------------------------------- 读写

def save(session_cookies: dict, login_mode: str = "") -> bool:
    """保存会话

    Args:
        session_cookies: {"jw": {name: value}, "cas": {name: value}}
        login_mode: "jw" / "cas" / "vruc"
    """
    global _CACHE, _LOADED

    payload = {
        "version": 1,
        "login_mode": login_mode,
        "jw": session_cookies.get("jw") or {},
        "cas": session_cookies.get("cas") or {},
    }
    _CACHE = payload
    _LOADED = True

    plain = json.dumps(payload, ensure_ascii=False)
    path = _data_file(SESSION_FILE_NAME)

    if sys.platform == "darwin":
        if _mac_encrypt(plain):
            try:
                if os.path.exists(path):
                    os.remove(path)
            except OSError:
                pass
            return True

    if sys.platform == "win32":
        blob = _dpapi_encrypt(plain)
        if blob:
            try:
                with open(path, "wb") as f:
                    f.write(blob)
                return True
            except OSError as e:
                logger.warning(f"写会话文件失败: {e}")
                return False

    # 兜底：0600 + base64
    try:
        with open(path, "wb") as f:
            f.write(base64.b64encode(plain.encode("utf-8")))
        os.chmod(path, 0o600)
        return True
    except OSError as e:
        logger.warning(f"写会话文件失败: {e}")
        return False


def load() -> Optional[dict]:
    """读取会话；不存在或损坏返回 None"""
    global _CACHE, _LOADED

    if _LOADED:
        return _CACHE

    _LOADED = True
    _CACHE = None

    plain: Optional[str] = None

    if sys.platform == "darwin":
        plain = _mac_decrypt()

    if plain is None:
        path = _data_file(SESSION_FILE_NAME)
        if not os.path.exists(path):
            return None
        try:
            raw = open(path, "rb").read()
        except OSError:
            return None

        if sys.platform == "win32":
            decrypted = _dpapi_decrypt(raw)
            if decrypted is not None:
                plain = decrypted
        if plain is None:
            try:
                plain = base64.b64decode(raw).decode("utf-8")
            except Exception:
                plain = raw.decode("utf-8", "replace")

    try:
        payload = json.loads(plain)
    except Exception:
        logger.warning("会话数据无法解析，按未登录处理")
        return None

    if not isinstance(payload, dict):
        return None
    _CACHE = payload
    return payload


def clear() -> None:
    """清除会话（退出登录时调用）"""
    global _CACHE, _LOADED
    _CACHE = None
    _LOADED = True

    if sys.platform == "darwin":
        try:
            subprocess.run(
                [
                    "security",
                    "delete-generic-password",
                    "-s",
                    KEYCHAIN_SERVICE,
                    "-a",
                    KEYCHAIN_ACCOUNT,
                ],
                capture_output=True,
                timeout=10,
            )
        except Exception:
            pass

    try:
        path = _data_file(SESSION_FILE_NAME)
        if os.path.exists(path):
            os.remove(path)
    except OSError as e:
        logger.warning(f"删除会话文件失败: {e}")


def apply_to_session(session, host: str) -> int:
    """把已保存的 cookie 灌进 requests.Session

    Args:
        session: requests.Session
        host: "jw.ruc.edu.cn" 或 "cas.ruc.edu.cn"

    Returns:
        灌入的 cookie 数量
    """
    payload = load()
    if not payload:
        return 0

    key = "cas" if host.startswith("cas.") else "jw"
    cookies = payload.get(key) or {}
    count = 0
    for name, value in cookies.items():
        try:
            session.cookies.set(name, value, domain=host, path="/")
            count += 1
        except Exception:
            continue
    return count


def snapshot(session) -> dict:
    """从 Session 抓取 jw / cas 两域的 cookie"""
    return {
        "jw": session.cookies.get_dict(domain="jw.ruc.edu.cn"),
        "cas": session.cookies.get_dict(domain="cas.ruc.edu.cn"),
    }
