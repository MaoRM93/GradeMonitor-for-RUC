"""开发机签名密钥访问层。

私钥只保存在 macOS 钥匙串的通用密码项中，绝不回退到应用支持目录、仓库或
安装包。更新/通知签名与远程控制签名严格使用两枚不同的密钥。
"""
from __future__ import annotations

from pathlib import Path
import subprocess

from cryptography.hazmat.primitives import serialization

KEYCHAIN_SERVICE = "GradeMonitorSigning"
CONTROL_KEY_SECRET = "control-signing-ed25519-v2"
RELEASE_KEY_SECRET = "release-signing-ed25519-v2"
_HELPER = Path(__file__).resolve().parents[1] / "bin" / "keychain_secret"


def _run_keychain(operation: str, account: str, data: bytes | None = None) -> bytes:
    if not _HELPER.is_file():
        raise FileNotFoundError("缺少开发机钥匙串辅助程序，请重新安装开发者工具。")
    result = subprocess.run(
        [str(_HELPER), operation, KEYCHAIN_SERVICE, account],
        input=data,
        capture_output=True,
        # 系统 Touch ID / 密码确认可能需要用户切回窗口，给足时间；这条路径
        # 只在开发者签发控制、通知或更新时使用，不影响普通用户运行。
        timeout=60,
    )
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise FileNotFoundError(message or "开发机钥匙串中缺少签名密钥")
    return result.stdout


def _load_ed25519(secret_name: str):
    pem = _run_keychain("read", secret_name)
    key = serialization.load_pem_private_key(pem, password=None)
    # 这里刻意不用宽泛的“能 sign 即可”：密钥种类不对必须立即失败。
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("钥匙串中的签名密钥不是 Ed25519 私钥")
    return key


def control_private_key():
    """专用于远程功能控制的独立 Ed25519 私钥。"""
    return _load_ed25519(CONTROL_KEY_SECRET)


def release_private_key():
    """专用于更新包与通知签名的 Ed25519 私钥。"""
    return _load_ed25519(RELEASE_KEY_SECRET)


def store_developer_key(secret_name: str, pem: bytes) -> None:
    """仅开发机初始化时写入；通过 stdin 交给 Security.framework，不经过 argv。"""
    _run_keychain("write", secret_name, pem)

