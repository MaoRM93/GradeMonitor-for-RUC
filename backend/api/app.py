# backend/api/app.py
"""
GradeMonitor Backend API - FastAPI 应用入口

启动方式: uvicorn backend.api.app:app --host 127.0.0.1 --port 18923
"""
import asyncio
import shutil
import subprocess
import sys
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, Any

from backend.auth.login import login_and_bind_jw
from backend.service.grade_service import GradeService
from backend.service.rank_service import RankService
from backend.service.monitor_service import monitor
from backend.service.notification_service import send_test_notification, send_notification_preview
from backend.storage.settings import load_settings, save_settings, DEFAULT_SETTINGS
from backend.storage.cache import (
    diff_grades,
    derive_semesters_from_local_grades,
    get_data_dir, get_data_file_path,
    load_total_query_count, increment_query_count, reset_query_count,
    load_local_grades, load_local_ranks,
    save_local_grades, save_local_ranks,
)
from backend.utils.logger import get_logger

logger = get_logger(__name__)

# ---------- 应用初始化 ----------
app = FastAPI(
    title="GradeMonitor API",
    description="自动查成绩后台服务",
)

# 允许本地 Flutter 应用跨域请求
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------- 请求/响应日志中间件 ----------
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start_time = time.time()
    logger.info(f"--> {request.method} {request.url.path}")
    try:
        response = await call_next(request)
        elapsed = (time.time() - start_time) * 1000
        logger.info(f"<-- {request.method} {request.url.path} {response.status_code} ({elapsed:.0f}ms)")
        return response
    except Exception as e:
        elapsed = (time.time() - start_time) * 1000
        logger.error(f"<-- {request.method} {request.url.path} ERROR ({elapsed:.0f}ms): {e}")
        raise


# ---------- 内存缓存（仅在查询时读写文件）----------
_grades_cache: dict = {}
_rank_cache: dict = {}


def _init_cache():
    """启动时从文件加载缓存到内存"""
    global _grades_cache, _rank_cache
    _grades_cache = load_local_grades()
    _rank_cache = load_local_ranks()
    logger.info(f"内存缓存初始化: {len(_grades_cache)} 门课程, rank={'有' if _rank_cache else '无'}")


def _update_grades_cache(new_data: dict):
    """更新内存中的成绩缓存并持久化到文件"""
    global _grades_cache
    _grades_cache = new_data
    save_local_grades(new_data)


def _update_rank_cache(new_data: dict):
    """更新内存中的排名缓存并持久化到文件"""
    global _rank_cache
    _rank_cache = new_data
    save_local_ranks(new_data)


def get_grades_cache() -> dict:
    return _grades_cache


def get_rank_cache() -> dict:
    return _rank_cache


# 注册 monitor 更新缓存的回调
def _on_monitor_grades_updated(grades_dict: dict):
    _update_grades_cache(grades_dict)


def _on_monitor_rank_updated(rank_dict: dict):
    _update_rank_cache(rank_dict)


def _refresh_cache_from_json():
    """从 JSON 文件重新读入内存缓存（用于监控检查前同步手动编辑）"""
    global _grades_cache, _rank_cache
    _grades_cache = load_local_grades()
    _rank_cache = load_local_ranks()


monitor.set_cache_callbacks(
    on_grades_updated=_on_monitor_grades_updated,
    on_rank_updated=_on_monitor_rank_updated,
    on_refresh_cache=_refresh_cache_from_json,
)


# ---------- 启动时初始化 ----------
_init_cache()

logger.info("=" * 50)
logger.info("GradeMonitor Backend 启动")
logger.info(f"日志目录: {Path(__file__).resolve().parent.parent.parent / 'logs'}")
logger.info("=" * 50)


@app.on_event("startup")
async def _startup():
    """应用启动：自动启动监控。

    必须在此处（而非模块导入时）启动，因为 asyncio.create_task 需要一个
    正在运行的 event loop；模块导入时 loop 尚未运行，会导致监控静默启动失败。
    """
    _settings = load_settings()
    if _settings.get("auto_monitor_enabled") or _settings.get("rank_monitor_enabled"):
        try:
            await monitor.start()
            logger.info("自动启动监控（auto_monitor_enabled=True）")
        except Exception as e:
            logger.warning(f"自动启动监控失败: {e}")


@app.on_event("shutdown")
async def _shutdown():
    await monitor.stop()


# ---------- 请求 / 响应模型 ----------
class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    success: bool
    message: str = ""


class SettingsUpdate(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None
    remember_me: Optional[bool] = None
    notify_mode: Optional[str] = None
    start_time: Optional[str] = None
    end_time: Optional[str] = None
    interval_seconds: Optional[int] = None
    auto_start: Optional[bool] = None
    auto_monitor_enabled: Optional[bool] = None
    rank_monitor_enabled: Optional[bool] = None
    show_menubar_icon: Optional[bool] = None
    no_auto_query: Optional[bool] = None
    hide_unknown_courses: Optional[bool] = None
    welcome_completed: Optional[bool] = None
    show_welcome_always: Optional[bool] = None


# ---------- API 端点 ----------


@app.get("/")
async def root():
    return {"status": "ok", "service": "GradeMonitor Backend"}


@app.post("/api/login", response_model=LoginResponse)
async def login(req: LoginRequest):
    import requests as req_lib
    session = req_lib.Session()
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
    })
    try:
        login_and_bind_jw(session, req.username, req.password)
        logger.info(f"用户 {req.username} 登录成功")
        return LoginResponse(success=True, message="登录成功")
    except Exception as e:
        logger.error(f"用户 {req.username} 登录失败: {e}")
        raise HTTPException(status_code=401, detail=str(e))
    finally:
        session.close()


@app.get("/api/grades")
async def get_grades():
    """获取成绩列表（从内存缓存，不从文件/API读取）"""
    global _grades_cache
    if not _grades_cache:
        return {"data": [], "message": "暂无成绩数据"}
    # 将 dict 格式转为 list 格式返回
    course_list = list(_grades_cache.values())
    logger.debug(f"返回缓存成绩: {len(course_list)} 门课程")
    return {"data": course_list, "errorCode": "success", "errorMessage": None}


@app.get("/api/grades/latest-change")
async def get_latest_change():
    """最近一次成绩/排名变动的通知内容（仪表板「最新动态」展示用）

    数据由 notification_service._show 在真实通知时自动写入 recent_change.json，
    测试/预览/启动提示不记录。
    """
    import json

    try:
        from backend.storage.cache import get_data_file_path

        path = get_data_file_path("recent_change.json")
        if Path(path).exists():
            with open(path, "r", encoding="utf-8") as f:
                return {"success": True, "change": json.load(f)}
    except Exception as e:
        logger.warning(f"读取最近变动记录失败: {e}")
    return {"success": True, "change": None}


@app.get("/api/rank")
async def get_rank():
    """获取排名信息（从内存缓存）"""
    global _rank_cache
    if not _rank_cache:
        return {"data": None, "message": "暂无排名数据"}
    logger.debug(f"返回缓存排名: pm={_rank_cache.get('pm')}")
    return {"data": _rank_cache}


@app.get("/api/settings")
async def get_settings():
    return load_settings()


@app.post("/api/settings")
async def update_settings(update: SettingsUpdate):
    current = load_settings()
    changed = {k: v for k, v in update.dict(exclude_none=True).items() if v is not None}
    for key, val in changed.items():
        current[key] = val
    save_settings(current)
    logger.info(f"设置已更新: {list(changed.keys())}")

    # 开机自启动设置变更时，同步到系统（macOS 登录项 / Windows 注册表）
    if "auto_start" in changed:
        try:
            from backend.utils.startup import set_startup_enabled
            set_startup_enabled(current["auto_start"])
            logger.info(f"开机自启动: {'已启用' if current['auto_start'] else '已禁用'}")
        except Exception as e:
            logger.warning(f"开机自启动设置失败: {e}")

    return {"success": True, "settings": current}


@app.get("/api/monitor/status")
async def get_monitor_status():
    settings = load_settings()
    last_q = monitor.last_query_at
    return {
        "auto_monitor_enabled": settings.get("auto_monitor_enabled", False),
        "rank_monitor_enabled": settings.get("rank_monitor_enabled", False),
        "interval_seconds": settings.get("interval_seconds", 300),
        "start_time": settings.get("start_time", "08:00"),
        "end_time": settings.get("end_time", "22:00"),
        "is_running": monitor.is_running,
        "last_query_at": last_q.isoformat() if last_q else None,
        "total_queries": load_total_query_count(),
    }


@app.post("/api/monitor/start")
async def start_monitor():
    try:
        await monitor.start()
        return {"success": True, "message": "监控已启动"}
    except Exception as e:
        logger.error(f"启动监控失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/monitor/stop")
async def stop_monitor():
    try:
        await monitor.stop()
        return {"success": True, "message": "监控已停止"}
    except Exception as e:
        logger.error(f"停止监控失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/monitor/restart")
async def restart_monitor():
    try:
        await monitor.restart()
        return {"success": True, "message": "监控已重启"}
    except Exception as e:
        logger.error(f"重启监控失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/notification/test")
async def test_notification():
    try:
        send_test_notification()
        logger.info("测试通知已发送")
        return {"success": True, "message": "测试通知已发送"}
    except Exception as e:
        logger.error(f"测试通知失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/notification/preview")
async def preview_notification(mode: str = "详细"):
    is_simple = mode == "简洁"
    preview = send_notification_preview(is_simple)
    return {"preview": preview}


# ---------- 欢迎页 ----------

@app.get("/api/welcome/status")
async def welcome_status():
    """获取欢迎页状态"""
    settings = load_settings()
    return {
        "welcome_completed": settings.get("welcome_completed", False),
        "show_welcome_always": settings.get("show_welcome_always", False),
        "has_credentials": bool(settings.get("username")),
    }


@app.post("/api/welcome/complete")
async def complete_welcome():
    """标记欢迎页已完成"""
    current = load_settings()
    current["welcome_completed"] = True
    save_settings(current)
    return {"success": True}


# ---------- 开发者工具 ----------

@app.post("/api/dev/query-once")
async def query_once():
    """立即查询一次成绩和排名，与本地JSON对比，有变化则弹通知"""
    from backend.service.notification_service import (
        send_grades_notification,
        send_rank_notification,
    )

    settings = load_settings()
    username = settings.get("username", "")
    password = settings.get("password", "")
    if not username or not password:
        raise HTTPException(status_code=400, detail="请先登录并保存凭据")

    is_simple = settings.get("notify_mode", "详细") == "简洁"
    results = {}

    # ---- 成绩查询+对比 ----
    try:
        # 1. 从本地 JSON 文件读取作为对比基准（不是内存缓存）
        old_grades = load_local_grades()
        if old_grades is None:
            # JSON 彻底无法解析：仍更新缓存，但不做对比通知（防止误报全量新增）
            logger.warning("[手动查询] 本地JSON损坏且无法修复，跳过成绩对比通知")
            gs = GradeService(username, password)
            result = gs.fetch_grade_json()
            new_dict = {}
            for course in result.get("data", []):
                kth = course.get("kth")
                if kth:
                    new_dict[kth] = course
            _update_grades_cache(new_dict)
            results["grades"] = {
                "total": len(new_dict),
                "new_count": 0,
                "changed_count": 0,
            }
            # 继续执行排名查询部分
        else:
            logger.info(f"[手动查询] 本地JSON中有 {len(old_grades)} 门课程")

            # 2. 从服务器获取最新数据
            gs = GradeService(username, password)
            result = gs.fetch_grade_json()
            new_dict = {}
            for course in result.get("data", []):
                kth = course.get("kth")
                if kth:
                    new_dict[kth] = course
            logger.info(f"[手动查询] 服务器返回 {len(new_dict)} 门课程")

            # 3. 对比差异
            new_courses, changed_courses = diff_grades(old_grades, new_dict)
            logger.info(
                f"[手动查询] 对比结果: 新增 {len(new_courses)} 门, 变动 {len(changed_courses)} 门"
            )

            # 4. 保存最新数据
            _update_grades_cache(new_dict)

            # 5. 有变化则发通知（首次也按统一模板通知）
            if new_courses or changed_courses:
                all_changed = new_courses + changed_courses
                logger.info(
                    f"[手动查询] 发送通知: new_courses={len(new_courses)}, "
                    f"changed_courses={len(changed_courses)}"
                )
                send_grades_notification(
                    new_count=len(new_courses),
                    changed_count=len(changed_courses),
                    course_details=all_changed,
                    is_simple=is_simple,
                )
                logger.info("[手动查询] 成绩变动通知已发送")
            else:
                logger.info("[手动查询] 无成绩变化，跳过通知")
            results["grades"] = {
                "total": len(new_dict),
                "new_count": len(new_courses),
                "changed_count": len(changed_courses),
            }
    except Exception as e:
        results["grades_error"] = str(e)
        logger.error(f"手动查询成绩失败: {e}")

    # ---- 排名查询+对比 ----
    try:
        old_rank = load_local_ranks()
        logger.info(f"[手动查询] 本地排名: pm={old_rank.get('pm') if old_rank else 'None'}")

        rs = RankService(username, password)
        new_rank = rs.fetch_latest_rank(derive_semesters_from_local_grades())
        if new_rank:
            logger.info(f"[手动查询] 服务器排名: pm={new_rank.get('pm')}")

            # 对比
            rank_changes = []
            if old_rank:
                if str(new_rank.get("pm", "")) != str(old_rank.get("pm", "")):
                    rank_changes.append(
                        f"专业排名: {old_rank.get('pm')}/{old_rank.get('countnum')} "
                        f"→ {new_rank.get('pm')}/{new_rank.get('countnum')}"
                    )
                if str(new_rank.get("bjpm", "")) != str(old_rank.get("bjpm", "")):
                    rank_changes.append(
                        f"班级排名: {old_rank.get('bjpm')}/{old_rank.get('bjgms')} "
                        f"→ {new_rank.get('bjpm')}/{new_rank.get('bjgms')}"
                    )
            elif new_rank:
                rank_changes.append("首次获取排名数据")

            # 保存
            _update_rank_cache(new_rank)

            # 有变化则发通知
            if rank_changes:
                send_rank_notification(
                    rank_data=new_rank,
                    change_msgs=rank_changes,
                    is_simple=is_simple,
                )
            results["rank"] = {
                "pm": new_rank.get("pm"),
                "changes": rank_changes,
            }
        else:
            results["rank"] = None
    except Exception as e:
        results["rank_error"] = str(e)
        logger.error(f"手动查询排名失败: {e}")

    count = increment_query_count()
    logger.info(f"手动查询完成 (累计查询: {count})")
    return {"success": True, "results": results, "message": "查询完成"}


@app.post("/api/dev/clear-cache")
async def clear_cache():
    global _grades_cache, _rank_cache
    _grades_cache = {}
    _rank_cache = {}
    cleaned = []
    for fname in ["local_grades.json", "local_ranks.json", "stats.json"]:
        fp = Path(get_data_file_path(fname))
        if fp.exists():
            fp.unlink()
            cleaned.append(fname)
    return {"success": True, "cleaned": cleaned, "message": f"已清理 {len(cleaned)} 个缓存文件"}


@app.post("/api/dev/clear-all-data")
async def clear_all_data():
    global _grades_cache, _rank_cache
    _grades_cache = {}
    _rank_cache = {}
    cleaned = []
    for fname in ["local_grades.json", "local_ranks.json", "settings.json", "stats.json"]:
        fp = Path(get_data_file_path(fname))
        if fp.exists():
            fp.unlink()
            cleaned.append(fname)
    return {"success": True, "cleaned": cleaned, "message": f"已清理 {len(cleaned)} 个数据文件"}


@app.get("/api/dev/open-log-dir")
async def open_log_dir():
    data_dir = str(get_data_dir())
    try:
        if sys.platform == "darwin":
            subprocess.run(["open", data_dir])
        elif sys.platform == "win32":
            subprocess.run(["explorer", data_dir])
        else:
            subprocess.run(["xdg-open", data_dir])
        return {"success": True, "path": data_dir}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/dev/data-dir")
async def get_data_dir_info():
    return {"path": str(get_data_dir()), "exists": get_data_dir().exists()}


# ---------- WebSocket 事件推送 ----------

@app.websocket("/ws/events")
async def websocket_events(websocket: WebSocket):
    await websocket.accept()
    await websocket.send_json({"type": "connected", "message": "已连接"})
    logger.info("WebSocket 客户端已连接")

    async def send_event(event: dict) -> None:
        try:
            await websocket.send_json(event)
        except Exception:
            pass

    monitor.add_listener(send_event)

    try:
        while True:
            data = await websocket.receive_text()
    except WebSocketDisconnect:
        logger.info("WebSocket 客户端断开连接")
    except Exception as e:
        logger.error(f"WebSocket 异常: {e}")
    finally:
        monitor.remove_listener(send_event)
