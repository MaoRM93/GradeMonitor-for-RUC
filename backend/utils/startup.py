# backend/utils/startup.py
"""
开机自启动管理
- macOS: 使用 AppleScript / System Events 设置登录项，可在「系统设置 → 登录项」中查看和管理
- Windows: 写入当前用户注册表 HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run
"""
import os
import subprocess
import sys

APP_NAME = "GradeMonitor"

# Windows 自启动：写入当前用户注册表 Run 键（无需管理员权限）
_WIN_RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
_WIN_RUN_VALUE = "GradeMonitor"


def _get_win_exe_path() -> str:
    """获取 Windows 应用可执行文件路径"""
    env_path = os.environ.get("GRADEMONITOR_APP_PATH", "")
    if env_path and os.path.exists(env_path):
        return env_path
    # PyInstaller 打包后（或开发模式下运行 python.exe）
    return sys.executable


def _win_is_startup_enabled() -> bool:
    """检查 Windows 注册表 Run 键是否包含自启动项"""
    import winreg
    try:
        key = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, _WIN_RUN_KEY, 0, winreg.KEY_QUERY_VALUE
        )
    except OSError:
        return False
    try:
        winreg.QueryValueEx(key, _WIN_RUN_VALUE)
        return True
    except FileNotFoundError:
        return False
    finally:
        winreg.CloseKey(key)


def _win_set_startup(enabled: bool) -> None:
    """写入/删除 Windows 注册表 Run 键的自启动项"""
    import winreg
    exe_path = _get_win_exe_path()
    if not exe_path:
        raise Exception("无法确定应用可执行文件路径")
    # 路径加引号，避免含空格路径无法正确启动
    value = f'"{exe_path}"'
    key = winreg.OpenKey(
        winreg.HKEY_CURRENT_USER, _WIN_RUN_KEY, 0, winreg.KEY_SET_VALUE
    )
    try:
        if enabled:
            winreg.SetValueEx(key, _WIN_RUN_VALUE, 0, winreg.REG_SZ, value)
        else:
            try:
                winreg.DeleteValue(key, _WIN_RUN_VALUE)
            except FileNotFoundError:
                pass
    finally:
        winreg.CloseKey(key)


def _get_app_path() -> str:
    """获取当前 .app 包的完整路径（打包后）"""
    # 1. 优先使用 Flutter 前端传入的环境变量
    env_path = os.environ.get("GRADEMONITOR_APP_PATH", "")
    if env_path and ".app" in env_path:
        app_path = env_path.split(".app")[0] + ".app"
        if os.path.exists(app_path):
            return app_path

    # 2. PyInstaller 打包模式
    if getattr(sys, "frozen", False):
        exe_path = sys.executable
        if ".app" in exe_path:
            return exe_path.split(".app")[0] + ".app"

    # 3. 搜索常见位置
    app_name = "GradeMonitor.app"
    search_paths = [
        os.path.join(os.path.expanduser("~"), "Applications", app_name),
        os.path.join("/Applications", app_name),
    ]
    # 从环境变量的可执行文件路径推断
    if env_path:
        parent = os.path.dirname(env_path)
        for _ in range(5):
            candidate = os.path.join(parent, app_name)
            if os.path.exists(candidate):
                return candidate
            parent = os.path.dirname(parent)

    for p in search_paths:
        if os.path.exists(p):
            return p

    return ""


def is_startup_enabled() -> bool:
    """检查是否已设置开机自启动（Windows 查注册表，macOS 查登录项）"""
    if sys.platform == "win32":
        return _win_is_startup_enabled()
    if sys.platform != "darwin":
        return False

    app_path = _get_app_path()
    if not app_path.endswith(".app"):
        return False

    app_name = os.path.splitext(os.path.basename(app_path))[0]

    try:
        script = (
            f'tell application "System Events"\n'
            f"set loginItems to name of every login item\n"
            f'if loginItems contains "{app_name}" then\n'
            f'return "yes"\n'
            f"else\n"
            f'return "no"\n'
            f"end if\n"
            f"end tell"
        )
        result = subprocess.run(
            ["osascript", "-"],
            input=script,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() == "yes"
    except Exception:
        return False


def set_startup_enabled(enabled: bool) -> None:
    """设置开机自启动（Windows 写注册表，macOS 写登录项）"""
    if sys.platform == "win32":
        _win_set_startup(enabled)
        return
    if sys.platform != "darwin":
        raise Exception("开机自启动仅支持 macOS 与 Windows")

    app_path = _get_app_path()

    if not app_path.endswith(".app"):
        raise Exception("开机自启动功能仅在打包为 .app 后可用。请先导出应用。")

    if enabled:
        _add_login_item(app_path)
    else:
        _remove_login_item(app_path)


def _add_login_item(app_path: str) -> None:
    """通过 AppleScript 添加登录项"""
    app_name = os.path.splitext(os.path.basename(app_path))[0]

    # 先尝试删除旧的（避免重复）
    try:
        _remove_login_item(app_path)
    except Exception:
        pass

    script = (
        f'tell application "System Events"\n'
        f"make login item at end with properties "
        f'{{path:"{app_path}", name:"{app_name}", hidden:true}}\n'
        f"end tell"
    )
    result = subprocess.run(
        ["osascript", "-"],
        input=script,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        raise Exception(f"添���登录项失败: {result.stderr.strip()}")


def _remove_login_item(app_path: str) -> None:
    """通过 AppleScript 删除登录项"""
    app_name = os.path.splitext(os.path.basename(app_path))[0]

    script = (
        f'tell application "System Events"\n'
        f'delete (every login item whose name is "{app_name}")\n'
        f"end tell"
    )
    subprocess.run(
        ["osascript", "-"],
        input=script,
        capture_output=True,
        text=True,
        timeout=15,
    )
