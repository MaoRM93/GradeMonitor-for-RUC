"""成绩变动的可选移动端通知转发器（Bark / MeoW / ntfy）。"""
import json
import threading
from urllib.parse import quote

import requests

from backend.storage.cache import atomic_write_json, get_data_file_path
from backend.storage.feature_gates import gate_enabled
from backend.utils.logger import get_logger

logger = get_logger(__name__)
_FILE = get_data_file_path("notification_forwarders.json")

DEFAULT_CONFIG = {
    "bark": {"enabled": False, "url": ""},
    "meow": {"enabled": False, "nickname": ""},
    "ntfy": {"enabled": False, "server": "https://ntfy.sh", "topic": ""},
}


def _config() -> dict:
    try:
        import json
        with open(_FILE, "r", encoding="utf-8") as f:
            raw = json.load(f)
        if not isinstance(raw, dict):
            raw = {}
    except Exception:
        raw = {}
    result = {k: dict(v) for k, v in DEFAULT_CONFIG.items()}
    for name, defaults in result.items():
        if isinstance(raw.get(name), dict):
            for key in defaults:
                if key in raw[name]:
                    defaults[key] = raw[name][key]
    return result


def public_config() -> dict:
    """返回配置状态，供不需要编辑凭据的调用方使用。"""
    cfg = _config()
    return {
        "bark": {"enabled": bool(cfg["bark"]["enabled"]), "configured": bool(cfg["bark"]["url"])},
        "meow": {"enabled": bool(cfg["meow"]["enabled"]), "configured": bool(cfg["meow"]["nickname"])},
        "ntfy": {"enabled": bool(cfg["ntfy"]["enabled"]), "configured": bool(cfg["ntfy"]["topic"]), "server": cfg["ntfy"]["server"]},
    }


def client_config() -> dict:
    """返回本机 UI 重启后回填所需的完整配置。

    只允许受一次性本地 API token 保护的客户端端点调用；不会传往远端或写入
    日志。用户的转发地址和 Topic 因此可以在重启后恢复到输入框。
    """
    return _config()


def save_config(incoming: dict) -> dict:
    current = _config()
    for channel in current:
        value = incoming.get(channel)
        if not isinstance(value, dict):
            continue
        for key in current[channel]:
            # 空的密钥字段代表「保持已保存配置」，避免 UI 读取不到密钥后误清除。
            if key in value and not (key in ("url", "nickname", "topic") and value[key] == ""):
                current[channel][key] = value[key]
    atomic_write_json(_FILE, current)
    return public_config()


def _send(cfg: dict, title: str, message: str) -> dict:
    results = {}
    bark = cfg["bark"]
    if bark["enabled"] and bark["url"]:
        try:
            r = requests.post(bark["url"].rstrip("/"), json={"title": title, "body": message, "group": "GradeMonitor"}, timeout=10)
            results["bark"] = "成功" if r.ok else f"HTTP {r.status_code}"
        except Exception as e:
            results["bark"] = f"失败：{e}"
    meow = cfg["meow"]
    if meow["enabled"] and meow["nickname"]:
        try:
            url = "https://api.chuckfang.com/" + quote(str(meow["nickname"]), safe="")
            r = requests.post(url, json={"title": title, "msg": message, "category": "成绩"}, timeout=10)
            results["meow"] = "成功" if r.ok and r.json().get("status") == 200 else "服务拒绝请求"
        except Exception as e:
            results["meow"] = f"失败：{e}"
    ntfy = cfg["ntfy"]
    if ntfy["enabled"] and ntfy["topic"]:
        try:
            base = str(ntfy["server"] or "https://ntfy.sh").rstrip("/")
            url = f"{base}/{quote(str(ntfy['topic']), safe='')}"
            # 强制按 UTF-8 JSON API 投递。部分 ntfy 反向代理无法可靠推断
            # json= 的请求类型，会把整个 JSON 当正文显示在 Android 客户端。
            payload = json.dumps(
                {
                    "title": title,
                    "message": message,
                    "tags": ["mortar_board"],
                    "priority": 4,
                },
                ensure_ascii=False,
            ).encode("utf-8")
            r = requests.post(
                url,
                data=payload,
                headers={"Content-Type": "application/json; charset=utf-8"},
                timeout=10,
            )
            results["ntfy"] = "成功" if r.ok else f"HTTP {r.status_code}"
        except Exception as e:
            results["ntfy"] = f"失败：{e}"
    return results


# 功能组编号 → 通道名；任一通道被远程关闭即静默跳过（不报错、不提示）
_CHANNEL_GATES = {
    "bark": "Flag-1030",
    "meow": "Flag-1031",
    "ntfy": "Flag-1032",
}


def _enabled_config() -> dict:
    """读取转发配置并剔除被功能组下线的通道。"""
    cfg = _config()
    for channel, gid in _CHANNEL_GATES.items():
        if channel in cfg and not gate_enabled(gid):
            cfg[channel] = dict(cfg[channel], enabled=False)
    return cfg


def forward_notification(title: str, message: str) -> None:
    """不阻塞监控循环；移动端服务不可用绝不影响本机通知。"""
    def run():
        try:
            results = _send(_enabled_config(), title, message)
            if results:
                logger.info(f"移动端通知转发结果: {results}")
        except Exception as e:
            logger.warning(f"移动端通知转发失败: {e}")
    threading.Thread(target=run, name="notification-forwarder", daemon=True).start()


def test_forwarder(channel: str) -> dict:
    gid = _CHANNEL_GATES.get(channel)
    if gid and not gate_enabled(gid):
        return {"success": False, "message": "该通道当前不可用"}
    cfg = _config()
    if channel not in cfg:
        return {"success": False, "message": "未知通道"}
    original = {k: dict(v) for k, v in cfg.items()}
    for name in cfg:
        cfg[name]["enabled"] = name == channel
    result = _send(cfg, "GradeMonitor 测试通知", "测试成功后，成绩或排名更新会通过此通道发送到你的设备。")
    _ = original
    text = result.get(channel, "该通道尚未配置")
    return {"success": text == "成功", "message": text}
