# backend/api/security.py
"""本地后端 API 的访问令牌（防本机跨域/第三方进程调用）

背景：uvicorn 监听 127.0.0.1:18923 且原先 CORS 为 `*`、端点零鉴权——
本机任意网页（浏览器 fetch 跨域读取）或任意本地程序都能读到成绩、
调用 /api/dev/*、甚至拿到已保存的密码。

方案：
  - 前端启动后端时通过环境变量 GRADEMONITOR_API_TOKEN 传入一次性随机令牌
    （64 位 base64，Random.secure 生成），令牌只存在于两个进程的内存中，
    不经网络传输、不写明文到 URL。
  - 每个请求带 `X-GradeMonitor-Token` 头；WebSocket 同样校验该头。
  - 后端自身记住"有效令牌"并持久化到 <数据目录>/api_token（0600），
    以便手动启动后端（开发调试）时前端仍能读取并复用同一令牌。
  - 未携带或错误令牌 → 401，且不泄露任何数据。

注意：这只是"本机隔离"层的加固，不替代真正的用户认证。
"""
import hmac
import os
import secrets
from typing import Optional

from backend.utils.logger import get_logger

logger = get_logger(__name__)

TOKEN_ENV = "GRADEMONITOR_API_TOKEN"
TOKEN_HEADER = "x-grademonitor-token"
_TOKEN_FILE_NAME = "api_token"

# 无需令牌即可访问的路径（健康检查 / 仅返回静态状态）
_PUBLIC_PATHS = {"/", "/docs", "/openapi.json", "/redoc"}

_current_token: Optional[str] = None


def _token_file_path() -> str:
    from backend.storage.cache import get_data_file_path

    return get_data_file_path(_TOKEN_FILE_NAME)


def _read_token_file() -> Optional[str]:
    try:
        path = _token_file_path()
        if not os.path.exists(path):
            return None
        with open(path, "r", encoding="utf-8") as f:
            value = f.read().strip()
        return value or None
    except Exception as e:
        logger.debug(f"读取 API token 文件失败: {e}")
        return None


def _write_token_file(token: str) -> None:
    try:
        path = _token_file_path()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(token)
    except Exception as e:
        logger.warning(f"写入 API token 文件失败（不影响本次运行）: {e}")


def init_token() -> str:
    """确定本次运行的有效令牌：优先环境变量（前端注入），否则复用/新建。"""
    global _current_token
    if _current_token:
        return _current_token

    env_token = (os.environ.get(TOKEN_ENV) or "").strip()
    if env_token:
        _current_token = env_token
        # 持久化，便于手动启动后端的场景复用同一令牌
        if _read_token_file() != env_token:
            _write_token_file(env_token)
        logger.info("API 鉴权已启用（令牌来自启动环境变量）")
        return _current_token

    existing = _read_token_file()
    if existing:
        _current_token = existing
        logger.info("API 鉴权已启用（令牌来自本地 token 文件）")
        return _current_token

    _current_token = secrets.token_urlsafe(48)
    _write_token_file(_current_token)
    logger.info("API 鉴权已启用（已生成新令牌并写入数据目录）")
    return _current_token


def get_token() -> str:
    return _current_token or init_token()


def is_public_path(path: str) -> bool:
    return path in _PUBLIC_PATHS


def token_valid(provided: Optional[str]) -> bool:
    """恒定时间比较，避免时序侧信道。"""
    expected = _current_token or init_token()
    if not provided or not expected:
        return False
    return hmac.compare_digest(str(provided), str(expected))


def header_token(header_value: Optional[str]) -> bool:
    return token_valid(header_value)
