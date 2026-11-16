# backend/storage/credentials.py
"""凭据安全存储（取代 settings.json 里的明文密码）

目标：教务系统密码不再以明文形式落盘，避免被备份/同步盘/同机其他账户读取。

三档实现（按平台自动选择，全部失败时降级但不抛异常）：
  1. macOS  : 登录钥匙串（generic password），service=GradeMonitor /
              account=jw-password。由系统加密，仅当前用户可读。
  2. Windows: DPAPI（CryptProtectData，绑定当前 Windows 用户账户），
              密文写入 <数据目录>/credentials.bin。
  3. 其它   : 0600 权限文件 + base64（仅兜底，会打 warning）。

设计约束：
  - 本模块只负责"密码"这一项；settings.json 的结构与其余字段完全不变。
  - 所有读写失败都返回 None / False，绝不抛异常打断 App。
  - 值缓存在进程内存，避免监控循环每轮都调用钥匙串（有 IO 开销）。

已知残余风险（记录备查）：macOS 写钥匙串时密码作为 `security` 命令行参数
传入，<同用户> 的其他进程理论上可在极短时间内从进程列表看到；这仍显著
优于长期明文落盘，且同用户进程本就能读取该用户的文件。
"""
import base64
import os
from pathlib import Path
import subprocess
import sys
from typing import Optional

from backend.utils.logger import get_logger

logger = get_logger(__name__)

# 钥匙串条目标识（固定，升级后仍能找回旧密码）
KEYCHAIN_SERVICE = "GradeMonitor"
KEYCHAIN_ACCOUNT = "jw-password"

_CRED_FILE_NAME = "credentials.bin"

# 进程内缓存：None 表示尚未读取；"" 表示已确认无密码
_cached: Optional[str] = None
_loaded = False


def _data_file(name: str) -> str:
    from backend.storage.cache import get_data_file_path

    return get_data_file_path(name)


# ---------------------------------------------------------------- macOS 钥匙串

def _mac_find() -> Optional[str]:
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
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.rstrip("\n")
        return None
    except Exception as e:
        logger.warning(f"读取钥匙串失败: {e}")
        return None


def _mac_save(password: str) -> bool:
    try:
        # -U：已存在则更新，避免重复条目
        r = subprocess.run(
            [
                "security",
                "add-generic-password",
                "-U",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
                password,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return r.returncode == 0
    except Exception as e:
        logger.warning(f"写入钥匙串失败: {e}")
        return False


def _mac_clear() -> None:
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
            text=True,
            timeout=10,
        )
    except Exception as e:
        logger.debug(f"清理钥匙串条目失败（可忽略）: {e}")


# ------------------------------------------------------------- Windows DPAPI

def _win_protect(data: bytes) -> Optional[bytes]:
    """CryptProtectData 加密（仅 Windows 可用）。"""
    try:
        import ctypes
        from ctypes import wintypes

        class DATA_BLOB(ctypes.Structure):
            _fields_ = [
                ("cbData", wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_ubyte)),
            ]

        crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        def to_blob(raw: bytes):
            buf = (ctypes.c_ubyte * len(raw)).from_buffer_copy(raw)
            blob = DATA_BLOB(len(raw), buf)
            return blob, buf

        def from_blob(blob: DATA_BLOB) -> bytes:
            size = blob.cbData
            return bytes(bytearray(blob.pbData[:size]))

        blob_in, keep_in = to_blob(data)
        blob_out = DATA_BLOB()
        CRYPTPROTECT_UI_FORBIDDEN = 0x1
        ok = crypt32.CryptProtectData(
            ctypes.byref(blob_in),
            None,
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            ctypes.byref(blob_out),
        )
        _ = keep_in
        if not ok:
            return None
        try:
            return from_blob(blob_out)
        finally:
            kernel32.LocalFree(blob_out.pbData)
    except Exception as e:
        logger.warning(f"DPAPI 加密失败: {e}")
        return None


def _win_unprotect(data: bytes) -> Optional[bytes]:
    """CryptUnprotectData 解密（仅 Windows 可用）。"""
    try:
        import ctypes
        from ctypes import wintypes

        class DATA_BLOB(ctypes.Structure):
            _fields_ = [
                ("cbData", wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_ubyte)),
            ]

        crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        buf = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
        blob_in = DATA_BLOB(len(data), buf)
        blob_out = DATA_BLOB()
        CRYPTPROTECT_UI_FORBIDDEN = 0x1
        ok = crypt32.CryptUnprotectData(
            ctypes.byref(blob_in),
            None,
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            ctypes.byref(blob_out),
        )
        if not ok:
            return None
        try:
            return bytes(bytearray(blob_out.pbData[: blob_out.cbData]))
        finally:
            kernel32.LocalFree(blob_out.pbData)
    except Exception as e:
        logger.warning(f"DPAPI 解密失败: {e}")
        return None


# -------------------------------------------------- 兜底：0600 文件 + base64

def _fallback_read() -> Optional[str]:
    path = _data_file(_CRED_FILE_NAME)
    try:
        if not os.path.exists(path):
            return None
        with open(path, "rb") as f:
            raw = f.read().strip()
        if not raw:
            return None
        return base64.b64decode(raw).decode("utf-8")
    except Exception as e:
        logger.warning(f"读取兜底凭据文件失败: {e}")
        return None


def _fallback_write(password: str) -> bool:
    path = _data_file(_CRED_FILE_NAME)
    try:
        data = base64.b64encode(password.encode("utf-8"))
        # 0600：仅当前用户可读写
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        return True
    except Exception as e:
        logger.warning(f"写入兜底凭据文件失败: {e}")
        return False


def _fallback_clear() -> None:
    path = _data_file(_CRED_FILE_NAME)
    try:
        if os.path.exists(path):
            os.remove(path)
    except Exception as e:
        logger.debug(f"清理兜底凭据文件失败（可忽略）: {e}")


# ------------------------------------------------------------------ 对外接口

def load_password(use_cache: bool = True) -> str:
    """读取已保存的密码；无密码时返回空字符串。"""
    global _cached, _loaded
    if use_cache and _loaded:
        return _cached or ""

    value: Optional[str] = None
    if sys.platform == "darwin":
        value = _mac_find()
    elif sys.platform == "win32":
        path = _data_file(_CRED_FILE_NAME)
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    blob = f.read()
                if blob:
                    plain = _win_unprotect(blob)
                    if plain is not None:
                        value = plain.decode("utf-8")
            except Exception as e:
                logger.warning(f"读取 DPAPI 凭据失败: {e}")
    else:
        value = _fallback_read()

    _cached = value or ""
    _loaded = True
    return _cached


def save_password(password: str) -> bool:
    """保存密码（空字符串等价于清除）。返回是否成功。"""
    global _cached, _loaded
    if not password:
        clear_password()
        return True

    ok = False
    if sys.platform == "darwin":
        ok = _mac_save(password)
    elif sys.platform == "win32":
        blob = _win_protect(password.encode("utf-8"))
        if blob is not None:
            try:
                path = _data_file(_CRED_FILE_NAME)
                # DPAPI 强加密，不额外依赖文件权限；仍写 0600 保守一些
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(blob)
                ok = True
            except Exception as e:
                logger.warning(f"写入 DPAPI 凭据失败: {e}")
    else:
        ok = _fallback_write(password)

    if not ok:
        logger.warning("凭据安全存储不可用，降级写入 0600 兜底文件")
        ok = _fallback_write(password)

    if ok:
        _cached = password
        _loaded = True
    return ok


def clear_password() -> None:
    """清除已保存的密码。"""
    global _cached, _loaded
    if sys.platform == "darwin":
        _mac_clear()
    elif sys.platform == "win32":
        path = _data_file(_CRED_FILE_NAME)
        try:
            if os.path.exists(path):
                os.remove(path)
        except Exception as e:
            logger.debug(f"清理 DPAPI 凭据失败（可忽略）: {e}")
    _fallback_clear()
    _cached = ""
    _loaded = True


def has_password() -> bool:
    """是否已保存密码（供 /api/settings 告知前端，不回传明文）。"""
    return bool(load_password())


# ------------------------------------------------- 命名密钥（多条目扩展）
#
# 上面那套 API 只服务"教务密码"这一项，钥匙串 account 固定为 jw-password。
# 开发者 GitHub 令牌需要第二条独立记录，因此在这里补一组按名字索引的通用
# 接口。**刻意不改动上面任何函数**：老路径的缓存语义（None 未读 / "" 已确认
# 为空）与文件布局保持不变，避免影响已发布版本的迁移。
#
# 名字会进文件名（Windows DPAPI 兜底）与钥匙串 account，故限制字符集。

_SECRET_NAME_OK = set("abcdefghijklmnopqrstuvwxyz0123456789-_")

# 每条密钥的进程内缓存：名字 → 值（None 表示尚未读取，"" 表示确认无值）
_secret_cache: dict[str, Optional[str]] = {}


def _check_secret_name(name: str) -> str:
    key = (name or "").strip()
    if not key or not set(key) <= _SECRET_NAME_OK:
        raise ValueError(f"非法的密钥名: {name!r}")
    return key


def _secret_file(name: str) -> str:
    return _data_file(f"credentials_{name}.bin")


def _mac_find_named(account: str) -> Optional[str]:
    try:
        helper = Path(__file__).resolve().parents[1] / "bin" / "keychain_secret"
        if helper.is_file():
            r = subprocess.run(
                [str(helper), "read", KEYCHAIN_SERVICE, account],
                capture_output=True,
                timeout=10,
            )
            if r.returncode == 0:
                return r.stdout.decode("utf-8")
            return None
        r = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                account,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.rstrip("\n")
        return None
    except Exception as e:
        logger.warning(f"读取钥匙串失败（{account}）: {e}")
        return None


def _mac_save_named(account: str, value: str) -> bool:
    try:
        helper = Path(__file__).resolve().parents[1] / "bin" / "keychain_secret"
        if helper.is_file():
            # 通过 stdin 传递凭据，不出现在 shell 历史、日志或进程 argv。
            r = subprocess.run(
                [str(helper), "write", KEYCHAIN_SERVICE, account],
                input=value.encode("utf-8"),
                capture_output=True,
                timeout=10,
            )
            return r.returncode == 0
        # 仅兼容尚未安装 helper 的旧开发环境；发行包包含 helper。
        r = subprocess.run(
            [
                "security",
                "add-generic-password",
                "-U",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                account,
                "-w",
                value,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return r.returncode == 0
    except Exception as e:
        logger.warning(f"写入钥匙串失败（{account}）: {e}")
        return False


def _mac_clear_named(account: str) -> None:
    try:
        helper = Path(__file__).resolve().parents[1] / "bin" / "keychain_secret"
        if helper.is_file():
            subprocess.run(
                [str(helper), "delete", KEYCHAIN_SERVICE, account],
                capture_output=True,
                timeout=10,
            )
            return
        subprocess.run(
            [
                "security",
                "delete-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                account,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception as e:
        logger.debug(f"清理钥匙串条目失败（{account}，可忽略）: {e}")


def _fallback_read_named(name: str) -> Optional[str]:
    path = _secret_file(name)
    try:
        if not os.path.exists(path):
            return None
        with open(path, "rb") as f:
            raw = f.read().strip()
        if not raw:
            return None
        return base64.b64decode(raw).decode("utf-8")
    except Exception as e:
        logger.warning(f"读取兜底凭据文件失败（{name}）: {e}")
        return None


def _fallback_write_named(name: str, value: str) -> bool:
    path = _secret_file(name)
    try:
        data = base64.b64encode(value.encode("utf-8"))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        return True
    except Exception as e:
        logger.warning(f"写入兜底凭据文件失败（{name}）: {e}")
        return False


def _fallback_clear_named(name: str) -> None:
    path = _secret_file(name)
    try:
        if os.path.exists(path):
            os.remove(path)
    except Exception as e:
        logger.debug(f"清理兜底凭据文件失败（{name}，可忽略）: {e}")


def load_secret(name: str, use_cache: bool = True) -> str:
    """读取命名密钥；不存在时返回空字符串。绝不抛异常。"""
    try:
        key = _check_secret_name(name)
    except ValueError as e:
        logger.warning(str(e))
        return ""

    if use_cache and _secret_cache.get(key) is not None:
        return _secret_cache[key] or ""

    value: Optional[str] = None
    if sys.platform == "darwin":
        value = _mac_find_named(key)
    elif sys.platform == "win32":
        path = _secret_file(key)
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    blob = f.read()
                if blob:
                    plain = _win_unprotect(blob)
                    if plain is not None:
                        value = plain.decode("utf-8")
            except Exception as e:
                logger.warning(f"读取 DPAPI 凭据失败（{key}）: {e}")
    else:
        value = _fallback_read_named(key)

    _secret_cache[key] = value or ""
    return _secret_cache[key] or ""


def save_secret(name: str, value: str) -> bool:
    """保存命名密钥；空值等价于清除。返回是否成功。"""
    try:
        key = _check_secret_name(name)
    except ValueError as e:
        logger.warning(str(e))
        return False

    if not value:
        clear_secret(key)
        return True

    ok = False
    if sys.platform == "darwin":
        ok = _mac_save_named(key, value)
    elif sys.platform == "win32":
        blob = _win_protect(value.encode("utf-8"))
        if blob is not None:
            try:
                path = _secret_file(key)
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(blob)
                ok = True
            except Exception as e:
                logger.warning(f"写入 DPAPI 凭据失败（{key}）: {e}")
    else:
        ok = _fallback_write_named(key, value)

    if not ok and sys.platform == "darwin":
        # macOS 钥匙串不可用时不能把 PAT 降级为 Base64 文件；那不是加密。
        # 失败由调用方显式提示用户检查钥匙串权限。
        logger.error(f"凭据安全存储不可用（{key}），已拒绝写入不安全兜底文件")
        return False
    if not ok:
        logger.warning(f"凭据安全存储不可用（{key}），降级写入受限兜底文件")
        ok = _fallback_write_named(key, value)

    if ok:
        _secret_cache[key] = value
    return ok


def clear_secret(name: str) -> None:
    """清除命名密钥。"""
    try:
        key = _check_secret_name(name)
    except ValueError as e:
        logger.warning(str(e))
        return

    if sys.platform == "darwin":
        _mac_clear_named(key)
    elif sys.platform == "win32":
        path = _secret_file(key)
        try:
            if os.path.exists(path):
                os.remove(path)
        except Exception as e:
            logger.debug(f"清理 DPAPI 凭据失败（{key}，可忽略）: {e}")
    _fallback_clear_named(key)
    _secret_cache[key] = ""


def has_secret(name: str) -> bool:
    return bool(load_secret(name))
