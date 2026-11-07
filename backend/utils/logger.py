# backend/utils/logger.py
"""
统一日志模块

- 同时输出到控制台和文件
- 日志文件输出到项目根目录 /logs/ 文件夹
- 按天自动轮转，保留最近 30 天
- 支持模块级 logger 获取
"""
import logging
import os
import sys
import tempfile
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

# ---------- 日志目录 ----------
_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent


def _windows_appdata_root() -> Path:
    """Windows 上取可用的 Roaming 根目录，避免 APPDATA 缺失时拼出相对路径。"""
    for key in ("APPDATA", "LOCALAPPDATA"):
        value = os.environ.get(key, "")
        if value and os.path.isabs(value):
            return Path(value)
    home = os.path.expanduser("~")
    return Path(home) / "AppData" / "Roaming"


def _resolve_log_dir() -> Path:
    """选择可写入的日志目录。

    开发态（仓库内运行）沿用 <项目根>/logs，便于直接看文件。
    打包态（后端被塞进 GradeMonitor.app/Contents/Resources）时项目根在
    已签名 bundle 内部——即便文件系统可写也绝不能往里写，否则会破坏
    代码签名封印（Sealed Resources），下次启动可能被判"已损坏"。
    因此打包态一律写到与前端日志同级的应用数据目录
    （~/Library/Application Support/GradeMonitor/logs），两边日志可一起排查。
    """
    candidates = []
    # 打包态判定：项目根落在某个 .app 包内部
    in_bundle = ".app/Contents/" in str(_PROJECT_ROOT)
    if not in_bundle:
        candidates.append(_PROJECT_ROOT / "logs")
    env_dir = os.environ.get("GRADEMONITOR_DATA_DIR", "")
    if env_dir:
        candidates.append(Path(env_dir) / "logs")
    candidates.append(
        Path(os.path.expanduser("~"))
        / "Library"
        / "Application Support"
        / "GradeMonitor"
        / "logs"
        if sys.platform == "darwin"
        else _windows_appdata_root() / "GradeMonitor" / "logs"
    )
    candidates.append(Path(os.path.expanduser("~")) / ".grademonitor" / "logs")

    for candidate in candidates:
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            probe = candidate / ".write_test"
            probe.write_text("ok")
            probe.unlink()
            return candidate
        except OSError:
            continue
    fallback = Path(tempfile.gettempdir()) / "GradeMonitor" / "logs"
    try:
        fallback.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return fallback


_LOG_DIR = _resolve_log_dir()

LOG_FILE = _LOG_DIR / "backend.log"


def get_log_dir() -> Path:
    """返回当前生效的日志目录（供 /api/dev/open-log-dir 等使用）"""
    return _LOG_DIR

# ---------- 日志格式 ----------
_LOG_FORMAT = logging.Formatter(
    fmt="%(asctime)s.%(msecs)03d | %(levelname)-5s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

# ---------- 全局日志级别 ----------
# 可通过环境变量 LOG_LEVEL 控制（默认 INFO）
_LOG_LEVEL_NAME = os.environ.get("LOG_LEVEL", "INFO").upper()
_LOG_LEVEL = getattr(logging, _LOG_LEVEL_NAME, logging.INFO)

# ---------- 根 Logger 配置 ----------
_root_logger = logging.getLogger("grademonitor")
_root_logger.setLevel(_LOG_LEVEL)

# 避免重复添加 handler
if not _root_logger.handlers:
    # 文件 handler：按天轮转，保留 30 天
    file_handler = TimedRotatingFileHandler(
        filename=str(LOG_FILE),
        when="midnight",
        interval=1,
        backupCount=30,
        encoding="utf-8",
    )
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(_LOG_FORMAT)
    _root_logger.addHandler(file_handler)

    # 控制台 handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(_LOG_LEVEL)
    console_handler.setFormatter(_LOG_FORMAT)
    _root_logger.addHandler(console_handler)


def get_logger(name: str) -> logging.Logger:
    """
    获取指定模块的 logger

    用法:
        from backend.utils.logger import get_logger
        logger = get_logger(__name__)
        logger.info("something happened")
    """
    return _root_logger.getChild(name)


# ---------- 便捷函数 ----------
def debug(msg: str, *args):
    _root_logger.debug(msg, *args)


def info(msg: str, *args):
    _root_logger.info(msg, *args)


def warning(msg: str, *args):
    _root_logger.warning(msg, *args)


def error(msg: str, *args):
    _root_logger.error(msg, *args)


def exception(msg: str, *args):
    _root_logger.exception(msg, *args)
