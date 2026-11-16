# backend/storage/flags.py
"""开发者开关（feature flags）持久化层。

设计要点（见 docs/DEV_FLAGS_CONTRACT.md 第 1 节）：
  - 独立文件 `feature_flags.json`，**不进 settings.json**——开关数量会随版本
    增补，混进 settings 会让设置接口的字段集合持续膨胀，也让"重置设置"
    意外清掉调试态。
  - 结构是扁平 `dict[str, bool]`，键名即 Flag 名。
  - 读：缺失键用 DEFAULT_FLAGS 补齐（**仅在真的补了键时才回写**，否则每次
    GET /api/developer/flags 都会写一次盘，既浪费也可能与并发写打架）。
  - 文件损坏 / 顶层不是 dict / 值不是 bool：回退默认值，绝不让一个坏文件
    把整个开发者面板打挂。
  - 写：整体覆盖 + 原子写（复用 cache.atomic_write_json）。
"""
import json
import os

from backend.storage.cache import atomic_write_json, get_data_file_path
from backend.utils.logger import get_logger

logger = get_logger(__name__)

FLAGS_FILE = get_data_file_path("feature_flags.json")

# ---------- 默认值（契约第 2、3 节，改名会让前端按钮与后端校验错位） ----------
DEFAULT_FLAGS: dict[str, bool] = {
    # 1. 界面调谐
    "Enable_PYFA_EvyGrde": False,   # 1.1 解除方案计算页的账号年级限制
    "Show_Feature_0A1B": False,     # 1.2 预留
    "Enable_Feature_1A2C": False,   # 1.3 预留
    "Enable_Feature_2B3D": True,    # 1.4 预留（唯一默认开启）
    # 2. 功能遥测（只记录状态，暂不接入业务）
    "Disable_Flag_Ntce114": False,  # 2.1
    "Disable_PYFA_Show": False,     # 2.2
    "Disable_DsabPg": False,        # 2.3
    "Disable_BluPg": False,         # 2.4
    "Disable_Ntce": False,          # 2.5
    "Disable_Resv06": False,        # 2.6
    "Disable_Resv07": False,        # 2.7
    "Disable_Resv08": False,        # 2.8
    "Disable_Resv09": False,        # 2.9
    "Disable_Resv10": False,        # 2.10
    "Disable_Resv11": False,        # 2.11
    "Disable_Resv12": False,        # 2.12
    "Disable_Resv13": False,        # 2.13
    "Disable_Resv14": False,        # 2.14
    "Disable_Resv15": False,        # 2.15
}


def _read_raw() -> dict:
    """读取原始 JSON；任何异常都返回空 dict（交由 load_flags 补默认值）。"""
    if not os.path.exists(FLAGS_FILE):
        return {}
    try:
        with open(FLAGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            logger.error("feature_flags.json 顶层结构异常，回退默认开关")
            return {}
        return data
    except Exception as e:
        logger.error(f"读取 feature_flags.json 失败，回退默认开关: {e}")
        return {}


def load_flags() -> dict:
    """返回完整开关表（DEFAULT_FLAGS 全键 + 磁盘值）。

    只有磁盘上缺键（或值不是 bool）时才会补默认并回写文件；
    内容完整时**不写盘**，避免每次读取都产生一次 IO。
    """
    raw = _read_raw()
    flags = dict(DEFAULT_FLAGS)
    changed = False

    for name, default in DEFAULT_FLAGS.items():
        if name in raw and isinstance(raw.get(name), bool):
            flags[name] = raw[name]
        else:
            # 缺失键 / 非 bool 值：用默认值并标记需要回写
            changed = True

    if changed:
        try:
            atomic_write_json(FLAGS_FILE, flags)
            logger.info("feature_flags.json 已补齐缺失开关并回写")
        except Exception as e:
            # 回写失败不影响本次读取（内存里已经是完整表）
            logger.warning(f"回写 feature_flags.json 失败: {e}")

    return flags


def save_flags(flags: dict) -> dict:
    """整体覆盖写入；只保留 DEFAULT_FLAGS 内的键，缺失键补默认值。"""
    payload = dict(DEFAULT_FLAGS)
    for name, value in (flags or {}).items():
        if name in payload and isinstance(value, bool):
            payload[name] = value
    atomic_write_json(FLAGS_FILE, payload)
    logger.info(f"feature_flags.json 已写入（{len(payload)} 个开关）")
    return payload


def set_flag(name: str, value: bool) -> dict:
    """设置单个开关并返回写入后的完整开关表。

    未知键直接忽略（调用方——API 层——负责先做 400 校验）。
    """
    flags = load_flags()
    if name in DEFAULT_FLAGS:
        flags[name] = bool(value)
        flags = save_flags(flags)
    return flags


def flag_enabled(name: str) -> bool:
    """读取单个开关；未知键视为关闭（不抛异常，业务侧无需防御）。"""
    return bool(load_flags().get(name, False))
