# backend/storage/settings.py
"""
应用设置持久化（~/.json 文件）
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
from backend.utils.logger import get_logger

logger = get_logger(__name__)

# ---------- settings.json ----------
SETTINGS_FILE = get_data_file_path("settings.json")

# 默认设置
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


def load_settings() -> dict:
    """加载设置，缺失字段使用默认值补全"""
    if not os.path.exists(SETTINGS_FILE):
        logger.debug("Settings file not found, using defaults")
        return dict(DEFAULT_SETTINGS)
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        # 补全缺失的默认字段
        for key, val in DEFAULT_SETTINGS.items():
            if key not in data:
                data[key] = val
        logger.debug("Settings loaded successfully")
        return data
    except Exception as e:
        logger.error(f"Failed to load settings: {e}")
        return dict(DEFAULT_SETTINGS)


def save_settings(settings: dict) -> None:
    """保存设置到 JSON 文件"""
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)


def reset_settings() -> dict:
    """重置所有设置为默认值"""
    save_settings(DEFAULT_SETTINGS)
    return dict(DEFAULT_SETTINGS)
