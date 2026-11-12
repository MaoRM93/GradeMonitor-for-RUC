# backend/service/notification_service.py
"""
系统通知服务
macOS 使用 osascript display notification，Windows 使用 win11toast (WinRT)。
"""
import os
import subprocess
import sys

from backend.utils.logger import get_logger

logger = get_logger(__name__)

# Windows 桌面应用显示 Toast 所需的应用标识（AUMID）
_WIN_AUMID = "GradeMonitor.GradeMonitor"
_win_aumid_registered = False

# 结构化字段里最多写入的课程条数（仪表板卡片展示上限）
_STRUCTURED_COURSE_LIMIT = 6
# 取不到值时的占位符（前端直接拼接，不能用空串）
_MISSING = "-"


def _pick_value(course: dict, key: str) -> str:
    """取课程字段的展示值，缺失/空值统一返回 '-'"""
    value = course.get(key)
    if value is None:
        return _MISSING
    text = str(value).strip()
    return text if text else _MISSING


def _course_name(course: dict) -> str:
    """课程名：真实数据键为 kcname，兼容已结构化的 name 键"""
    name = _pick_value(course, "kcname")
    if name == _MISSING:
        name = _pick_value(course, "name")
    return name


def _calc_pjxfjd(course: dict) -> str:
    """单课平均学分绩点：绩点/学分，保留 1 位小数（最高 4.0）"""
    try:
        jd_val = float(course.get("jd", 0) or 0)
        xf_val = float(course.get("xf", 1) or 1)
    except (TypeError, ValueError):
        return "N/A"
    return f"{jd_val / xf_val:.1f}" if xf_val > 0 else "N/A"


def _build_grades_extra(course_details: list = None,
                        kind: str = "grades") -> dict:
    """构造 recent_change.json 的结构化字段（向后兼容：不改动 title/message/at）。

    - courseCount：本次传入的课程总数（不是截断后的条数）
    - courses：最多 6 条，按传入顺序
    - gpa 取 _calc_pjxfjd，无法计算/缺字段时记 '-'
    """
    courses = course_details or []
    items: list[dict] = []
    for course in courses[:_STRUCTURED_COURSE_LIMIT]:
        if not isinstance(course, dict):
            continue
        # 绩点字段缺失或为空时不宜用 0 兜底，统一记为 '-'
        gpa = _MISSING
        if _pick_value(course, "jd") != _MISSING:
            gpa = _calc_pjxfjd(course)
            if gpa == "N/A":
                gpa = _MISSING
        items.append({
            "name": _course_name(course),
            "gpa": gpa,
            "daily": _pick_value(course, "cjxm1"),
            "final": _pick_value(course, "cjxm3"),
            "weighted": _pick_value(course, "zcj"),
        })
    return {
        "kind": kind,
        "courseCount": len(courses),
        "courses": items,
    }


def send_startup_notification(auto_monitor_enabled: bool,
                               start_time: str = "08:00",
                               end_time: str = "22:00",
                               interval: int = 300) -> None:
    if auto_monitor_enabled:
        message = f"程序将在后台自动按设置监测成绩和排名（监测时段：{start_time}-{end_time}，间隔：{interval}秒）"
    else:
        message = "程序已启动，将按照您的设置进行后台监测"
    _show("自动查成绩小工具", message, record=False)


def send_grades_notification(new_count: int, changed_count: int,
                              course_details: list = None,
                              rank_pm: str = "N/A", rank_countnum: str = "N/A",
                              rank_bjpm: str = "N/A", rank_bjgms: str = "N/A",
                              is_simple: bool = False) -> None:
    """
    成绩变化通知

    简洁模式:
      标题：您有成绩或排名更新
      正文：无

    详细模式:
      单门：标题=您有成绩或排名更新：{课程名}
            正文第一行：平时分：xx；期末分：xx；加权分：xx
            正文第二行：平均学分绩点：x.x；班名：xx；年名：xx
      多门：标题=您有成绩或排名更新：{首课程名} 等 N 门
            正文逐门列出：课程名：平时xx 期末xx 加权xx 绩点x.x
    """
    if is_simple:
        # 简洁模式正文为空，但仍写入结构化字段供仪表板卡片消费
        _structured = _build_grades_extra(course_details)
        _show("您有成绩或排名更新", "", extra=_structured)
        return

    total = len(course_details) if course_details else 0
    if total == 0:
        return

    # 加载排名数据（班名、年名）
    bjpm = "N/A"
    pm = "N/A"
    try:
        from backend.storage.cache import load_local_ranks
        rank = load_local_ranks()
        if rank:
            bjpm = str(rank.get("bjpm", "N/A"))
            pm = str(rank.get("pm", "N/A"))
    except Exception:
        pass

    def _format_course(course: dict) -> dict:
        """提取课程展示字段"""
        return {
            "name": course.get("kcname", "未知课程"),
            "cjxm1": course.get("cjxm1", "N/A"),
            "cjxm3": course.get("cjxm3", "N/A"),
            "zcj": course.get("zcj", "N/A"),
            "pjxfjd": _calc_pjxfjd(course),
        }

    # recent_change.json 的结构化字段（一次构造，两种模式共用）
    structured = _build_grades_extra(course_details)

    if total == 1:
        c = _format_course(course_details[0])
        title = f"您有成绩或排名更新：{c['name']}"
        lines = [
            f"平时分：{c['cjxm1']}；期末分：{c['cjxm3']}；加权分：{c['zcj']}",
            f"平均学分绩点：{c['pjxfjd']}；班名：{bjpm}；年名：{pm}",
        ]
        _show(title, "\n".join(lines), extra=structured)
    else:
        first_name = course_details[0].get("kcname", "未知课程")
        title = f"您有成绩或排名更新：{first_name} 等 {total} 门"
        lines = []
        for course in course_details:
            c = _format_course(course)
            lines.append(f"{c['name']}：平时{c['cjxm1']} 期末{c['cjxm3']} 加权{c['zcj']} 绩点{c['pjxfjd']}")
        _show(title, "\n".join(lines), extra=structured)


def send_rank_notification(rank_data: dict, change_msgs: list = None,
                            is_simple: bool = False) -> None:
    # 排名类通知同样写结构化字段，但不带课程明细
    structured = {"kind": "rank", "courseCount": 0, "courses": []}

    if is_simple:
        _show("您有成绩或排名更新", "", extra=structured)
        return

    pm = rank_data.get("pm", "N/A")
    bjpm = rank_data.get("bjpm", "N/A")
    pjxfjd = rank_data.get("pjxfjd", "N/A")
    title = "您有成绩或排名更新：排名"
    lines = [
        f"平均学分绩点：{pjxfjd}",
        f"年名：{pm}；班名：{bjpm}",
    ]
    if change_msgs:
        lines.append("--- 变化 ---")
        lines.extend(change_msgs[:3])
    _show(title, "\n".join(lines), extra=structured)


def send_test_notification(is_simple: bool = False,
                            course_details: list = None) -> None:
    """测试通知：展示详细或简洁模式的实际通知内容"""
    if is_simple:
        _show("您有成绩或排名更新", "", record=False)
        return

    # 构造模拟数据展示格式
    course_name = "高等数学"
    if course_details:
        course_name = course_details[0].get("kcname", "高等数学")

    title = f"您有成绩或排名更新：{course_name}"
    message = (
        "平时分：90；期末分：82；加权分：85.5\n"
        "平均学分绩点：3.7；班名：3；年名：15"
    )
    _show(title, message, record=False)


def send_notification_preview(is_simple: bool) -> str:
    """返回通知预览文本（供前端展示）"""
    if is_simple:
        return "标题：您有成绩或排名更新\n内容：（无正文）"

    return (
        "标题：您有成绩或排名更新：高等数学\n"
        "正文：\n"
        "  平时分：90；期末分：82；加权分：85.5\n"
        "  平均学分绩点：3.7；班名：3；年名：15"
    )


def _ensure_win_aumid() -> None:
    """注册 Windows 桌面应用的 AppUserModelID（AUMID）。

    Windows 非 MSIX 打包的桌面应用显示 Toast 通知前，必须存在一个带
    System.AppUserModel.ID 的「开始菜单」快捷方式，否则 WinRT Toast 不会弹出。
    这里通过 PowerShell 一次性创建该快捷方式（指向应用本体 exe）。
    """
    global _win_aumid_registered
    if _win_aumid_registered:
        return
    # 无论成败只尝试一次，避免每次发通知都重复执行 PowerShell
    _win_aumid_registered = True
    try:
        app_exe = os.environ.get("GRADEMONITOR_APP_PATH", "") or sys.executable
        app_dir = os.path.dirname(app_exe) or app_exe
        # 通过环境变量传参，避免 PowerShell 命令行引号转义问题
        script = (
            "$ErrorActionPreference='SilentlyContinue';"
            "$lnkDir=Join-Path $env:APPDATA "
            "'Microsoft\\Windows\\Start Menu\\Programs';"
            "$lnkPath=Join-Path $lnkDir 'GradeMonitor.lnk';"
            "$ws=New-Object -ComObject WScript.Shell;"
            "$sc=$ws.CreateShortcut($lnkPath);"
            "$sc.TargetPath=$env:GM_APP_EXE;"
            "$sc.WorkingDirectory=$env:GM_APP_DIR;"
            "$sc.Description='GradeMonitor';"
            "$sc.Save();"
            "$sh=New-Object -ComObject Shell.Application;"
            "$folder=$sh.Namespace($lnkDir);"
            "$item=$folder.ParseName('GradeMonitor.lnk');"
            "if($item){"
            "$item.ExtendedProperty('System.AppUserModel.ID').Value=$env:GM_AUMID"
            "}"
        )
        env = os.environ.copy()
        env["GM_APP_EXE"] = app_exe
        env["GM_APP_DIR"] = app_dir
        env["GM_AUMID"] = _WIN_AUMID
        subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-Command", script],
            check=False,
            timeout=15,
            capture_output=True,
            env=env,
        )
        logger.info(f"Windows AUMID 快捷方式已注册: {_WIN_AUMID}")
    except Exception as e:
        logger.warning(f"Windows AUMID 注册失败（通知可能无法显示）: {e}")


def _win_toast_launch_target() -> str:
    """返回点击 Windows Toast 时要激活的命令行（带引号），不可用时返回空串。

    win11toast 的 `on_click` 传字符串时会写入 toast 的 `launch` 属性，
    Windows 以 activationType="protocol" 用 ShellExecute 执行它。这里指向
    应用本体 exe：exe 启动后由 main.cpp 的单实例互斥体检测到已有实例，
    直接把主窗口还原并置前，然后自身退出——因此点击通知即可回到主界面，
    不会重复拉起后端进程。
    """
    app_exe = os.environ.get("GRADEMONITOR_APP_PATH", "")
    if not app_exe or not os.path.isfile(app_exe):
        return ""
    return f'"{app_exe}"'


def _show(title: str, message: str, record: bool = True,
          extra: dict | None = None) -> None:
    """发送 macOS/Windows 系统通知。

    **macOS 改为由 App 自身的原生通知通道投递**（前端
    flutter_local_notifications → UNUserNotification），原因是
    `osascript display notification` 由 Script Editor/osascript 代发：
    通知图标是系统通用占位图（不是本 App 图标），点击也不会回到 App。
    改由 App 进程投递后，图标即 App 图标、点击可激活主窗口、且可被
    「聚焦」等系统设置归类到本 App 下。

    仅当前端 WebSocket 未连接时才回退 osascript（保证仍能收到提醒）。

    注意：**通知内容、触发条件、去重与对比逻辑完全不变**，这里只是把
    "由谁弹出这条通知"从前端 osascript 换成 App 自己的原生通道。

    [record] 是否持久化到 recent_change.json（仪表板「最新动态」读取汇总），
    测试/预览通知传 False 避免覆盖真实变动记录。

    [extra] 额外写入 recent_change.json 的结构化字段（如 kind/courseCount/courses）。
    只会**新增**键，title/message/at 的原有写入方式与格式完全不变，
    因此系统通知与其他消费方不受影响。record=False 时不写文件，extra 被忽略。

    注意：写文件与后续通知投递使用的是同一份 _data 语义 —— WebSocket 分支
    与 osascript/win11toast 回退分支都只消费 title/message，互不影响。
    """
    if record:
        try:
            from datetime import datetime

            from backend.storage.cache import atomic_write_json, get_data_file_path

            _data = {
                "title": title,
                "message": message,
                "at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            }
            # 结构化字段：向后兼容地追加以供仪表板卡片消费
            if extra:
                for key, value in extra.items():
                    if key in ("title", "message", "at"):
                        # 保护原有三字段，禁止被 extra 覆盖
                        continue
                    _data[key] = value
            atomic_write_json(get_data_file_path("recent_change.json"), _data)
        except Exception as e:
            logger.debug(f"记录最近通知失败: {e}")

    # macOS：优先交给 App 原生通知（正确图标 + 可点击回 App）
    if sys.platform == "darwin":
        if _try_send_via_websocket(title, message):
            logger.info(f"通知已交由 App 原生通道投递: {title}")
            return
        logger.debug("App 原生通道不可用，回退 osascript")

    try:
        if sys.platform == "darwin":
            escaped_title = title.replace('"', '\\"').replace("'", "\\'")
            escaped_message = message.replace('"', '\\"').replace("'", "\\'")
            script = (
                f'display notification "{escaped_message}"'
                f' with title "{escaped_title}"'
            )
            logger.info(f"Executing AppleScript: {script}")
            subprocess.run(["osascript", "-e", script], check=True)
            logger.info(f"Notification sent via osascript: {title}")
        elif sys.platform == "win32":
            try:
                from win11toast import notify

                _ensure_win_aumid()
                # on_click 传字符串 → 写入 toast 的 launch 属性；点击通知时
                # ShellExecute 该命令行，由单实例互斥体把主窗口还原置前。
                launch = _win_toast_launch_target()
                if launch:
                    notify(title, message, app_id=_WIN_AUMID, on_click=launch)
                else:
                    notify(title, message, app_id=_WIN_AUMID)
                logger.info(f"Notification sent via win11toast: {title}")
            except ImportError:
                logger.warning("win11toast 未安装，请执行: pip install win11toast")
    except subprocess.CalledProcessError as e:
        logger.error(
            f"osascript 执行失败 (exit code {e.returncode}):\n"
            f"  stdout: {e.stdout.decode('utf-8', errors='replace') if e.stdout else '(empty)'}\n"
            f"  stderr: {e.stderr.decode('utf-8', errors='replace') if e.stderr else '(empty)'}"
        )
    except Exception as e:
        logger.error(f"Failed to send notification: {e}")


def _try_send_via_websocket(title: str, message: str) -> bool:
    """通过 MonitorService 的 WebSocket 广播 show_notification 事件。

    返回 True 表示已投递（存在至少一个前端 WebSocket 连接）；
    False 表示无可用前端通道，调用方应回退 osascript。

    只负责"把通知交给 App 进程弹出"，不参与任何通知内容的生成。
    """
    try:
        import asyncio

        from backend.service.monitor_service import monitor

        # 没有前端连接时无法投递，交给 osascript 兜底
        if not monitor._listeners:
            logger.debug("WebSocket 无连接客户端，回退 osascript")
            return False

        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            logger.debug("无运行中的 event loop，回退 osascript")
            return False

        payload = {
            "type": "show_notification",
            "title": title,
            "message": message,
        }
        loop.create_task(monitor._broadcast(payload))
        return True
    except Exception as e:
        logger.debug(f"WebSocket 广播失败，回退 osascript: {e}")
        return False
