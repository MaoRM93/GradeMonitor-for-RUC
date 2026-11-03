# backend/storage/settings.py
"""
应用设置持久化（~/.json 文件）

安全约定（2026-11 加固）：
  - **密码永不写入 settings.json**：落盘前从 dict 中剥离，转存系统安全存储
    （macOS 钥匙串 / Windows DPAPI，见 storage/credentials.py）。
  - 但 `load_settings()` 仍会把密码**回填进返回的 dict**，因此
    monitor_service / api 里既有的 `settings.get("password")` 读法完全不变
    ——成绩检测、排名检测、推送内容的算法零改动。
  - 对外 HTTP 响应必须用 `public_settings()` 剥离密码，避免 /api/settings
    把凭据回传给任意本机调用方。
"""
import json
import os

from backend.storage.cache import (
    APPDATA_DIR,
    APP_NAME,
    ensure_data_dir,
    get_data_dir,
    get_data_file_path,
)
from backend.storage.credentials import (
    clear_password,
    has_password,
    load_password,
    save_password,
)
from backend.utils.logger import get_logger

logger = get_logger(__name__)

# ---------- settings.json ----------
SETTINGS_FILE = get_data_file_path("settings.json")

# 默认设置（password 仅为内存中的默认占位，不落盘）
DEFAULT_SETTINGS = {
    "username": "",
    "password": "",
    "remember_me": False,
    "notify_mode": "详细",
    "start_time": "08:00",
    "end_time": "23:00",
    "interval_seconds": 300,
    "auto_start": False,
    "auto_monitor_enabled": False,
    "rank_monitor_enabled": False,
    "show_menubar_icon": True,
    "no_auto_query": False,
    "hide_unknown_courses": True,
    "random_interval_enabled": True,
    "welcome_completed": False,
    "show_welcome_always": False,
}

# 绝不写入 settings.json 的敏感字段
_SECRET_KEYS = ("password",)


def _read_raw() -> dict:
    """读取 settings.json 的原始内容（不做密码回填）。"""
    if not os.path.exists(SETTINGS_FILE):
        logger.debug("Settings file not found, using defaults")
        return {}
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            logger.error("settings.json 顶层结构异常，按空设置处理")
            return {}
        return data
    except Exception as e:
        logger.error(f"Failed to load settings: {e}")
        return {}


def _migrate_plaintext_password(raw: dict) -> None:
    """把旧版本遗留在 settings.json 里的明文密码迁移进安全存储并抹掉。

    仅在读到明文密码时触发；迁移成功后重写文件（不含密码）。
    """
    legacy = raw.get("password")
    if not isinstance(legacy, str) or not legacy:
        return
    logger.info("检测到 settings.json 中的明文密码，正在迁移至系统安全存储")
    if save_password(legacy):
        # 从原始数据中移除并重写文件
        raw.pop("password", None)
        try:
            with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
                json.dump(raw, f, ensure_ascii=False, indent=2)
            logger.info("明文密码已迁移，settings.json 已重写（不含密码）")
        except Exception as e:
            logger.warning(f"重写 settings.json 失败（明文仍存在，请检查权限）: {e}")
    else:
        logger.warning("迁移明文密码失败，暂保留原状以免丢失凭据")


def load_settings() -> dict:
    """加载设置，缺失字段使用默认值补全。

    返回的 dict 中 `password` 字段由系统安全存储回填，
    调用方无需感知密码的实际存储位置。
    """
    raw = _read_raw()
    _migrate_plaintext_password(raw)

    data = dict(DEFAULT_SETTINGS)
    for key, val in raw.items():
        if key in _SECRET_KEYS:
            continue
        data[key] = val

    # 密码始终来自安全存储（回填，保持既有调用方式不变）
    data["password"] = load_password()
    logger.debug("Settings loaded successfully")
    return data


def save_settings(settings: dict) -> None:
    """保存设置到 JSON 文件；密码转存系统安全存储，不落盘明文。

    只有调用方**显式提供** `password` 键时才触碰凭据存储：
      - 非空 → 保存
      - 空串 → 清除
    未提供该键时保持安全存储中的既有密码不变。这一点很关键——前端不再
    持有明文密码，它保存其他开关时传来的 settings 里 password 为空，
    若把"空"当成"清除"就会误删用户已保存的密码。
    """
    payload = {k: v for k, v in settings.items() if k not in _SECRET_KEYS}

    if "password" in settings:
        password = settings.get("password")
        if isinstance(password, str):
            if password:
                save_password(password)
            else:
                clear_password()

    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def public_settings() -> dict:
    """可安全返回给前端的设置（密码替换为布尔标记）。"""
    data = load_settings()
    data["password"] = ""
    data["has_password"] = has_password()
    return data


def reset_settings() -> dict:
    """重置所有设置为默认值（同时清除已保存的密码）。"""
    save_settings(dict(DEFAULT_SETTINGS))
    clear_password()
    return dict(DEFAULT_SETTINGS)
