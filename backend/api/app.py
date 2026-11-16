# backend/api/app.py
"""
GradeMonitor Backend API - FastAPI 应用入口

启动方式: uvicorn backend.api.app:app --host 127.0.0.1 --port 18923
"""
import asyncio
import base64
import hashlib
import shutil
import subprocess
import sys
import time
import os
import requests
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional, Any

from backend.api.security import (
    TOKEN_HEADER,
    header_token,
    init_token,
    is_public_path,
)
from backend.auth.login import (
    ALL_MODES,
    DEFAULT_MODE,
    KIND_CAPTCHA_INVALID,
    KIND_CAPTCHA_REQUIRED,
    LoginError,
    login_by_mode,
    mode_needs_captcha,
    normalize_mode,
    try_restore_session,
)
from backend.auth import cas_login, jw_login, session_store
from backend.service.grade_service import GradeService
from backend.service.rank_service import RankService
from backend.service.monitor_service import monitor
from backend.service.notification_service import send_test_notification, send_notification_preview
from backend.service.forwarder_service import public_config, save_config, test_forwarder
from backend.service.curriculum_service import open_curriculum, view_curriculum
from backend.service import developer_auth
from backend.storage.flags import DEFAULT_FLAGS, load_flags, set_flag
from backend.storage.feature_gates import (
    DEFAULT_GATES,
    gate_enabled,
    load_gates,
    registry_payload,
    save_gates,
    set_gate,
)
from backend.storage import remote_gates
from backend.storage.settings import (
    load_settings,
    public_settings,
    save_settings,
    DEFAULT_SETTINGS,
)
from backend.storage.cache import (
    diff_grades,
    derive_semesters_from_local_grades,
    get_data_dir, get_data_file_path,
    load_total_query_count, increment_query_count, reset_query_count,
    load_local_grades, load_local_ranks,
    save_local_grades, save_local_ranks,
)
from backend.utils.logger import get_logger, get_log_dir

logger = get_logger(__name__)

# ---------- 应用初始化 ----------
app = FastAPI(
    title="GradeMonitor API",
    description="自动查成绩后台服务",
)

# 启动时确定本次运行的访问令牌（来自前端注入的环境变量，或本地 token 文件）
_API_TOKEN = init_token()

# 远程开关拉取循环的 task 句柄。asyncio 只保留 task 的弱引用，不挂在模块级
# 会被 GC 提前回收；同时 shutdown 时需要它来 cancel。
_gate_task: Optional[asyncio.Task] = None

# CORS 收紧：只允许本机同源访问。原先的 allow_origins=["*"] 会让任意网页
# 读取本机成绩/设置；现在仅放行 127.0.0.1 / localhost 的常见端口形态。
# 真正的防跨站保护由下面的令牌校验负责（CORS 只是额外一层）。
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"^(http://(127\.0\.0\.1|localhost)(:\d+)?|file://.*)$",
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*", TOKEN_HEADER],
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


# ---------- 访问令牌校验中间件 ----------
@app.middleware("http")
async def require_api_token(request: Request, call_next):
    """所有 /api/* 端点必须携带有效令牌（健康检查与文档路径除外）。

    令牌由前端拉起后端时通过 GRADEMONITOR_API_TOKEN 注入，或由后端生成
    后写入 <数据目录>/api_token（0600）供本地复用；不随网络传输明文。
    未通过的请求在进入业务逻辑前即返回 401，不泄露任何数据。
    """
    path = request.url.path
    # CORS 预检请求放行（浏览器 OPTIONS 不带自定义头）
    if request.method == "OPTIONS":
        return await call_next(request)
    if is_public_path(path):
        return await call_next(request)

    provided = request.headers.get(TOKEN_HEADER) or request.headers.get("Authorization", "")
    if provided.lower().startswith("bearer "):
        provided = provided[7:]
    if not header_token(provided):
        logger.warning(f"拒绝未授权请求: {request.method} {path}")
        return JSONResponse(
            status_code=401,
            content={"detail": "unauthorized: missing or invalid API token"},
        )
    return await call_next(request)


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
logger.info(f"日志目录: {get_log_dir()}")
logger.info("=" * 50)


@app.on_event("startup")
async def _startup():
    """应用启动：自动启动监控，并起一个远程开关拉取循环。

    必须在此处（而非模块导入时）启动，因为 asyncio.create_task 需要一个
    正在运行的 event loop；模块导入时 loop 尚未运行，会导致监控静默启动失败。
    """
    global _gate_task

    _settings = load_settings()
    if _settings.get("auto_monitor_enabled") or _settings.get("rank_monitor_enabled"):
        try:
            await monitor.start()
            logger.info("自动启动监控（auto_monitor_enabled=True）")
        except Exception as e:
            logger.warning(f"自动启动监控失败: {e}")

    _gate_task = asyncio.create_task(_gate_refresh_loop())
    logger.info("远程功能开关拉取循环已启动（每小时一次）")


async def _gate_refresh_loop() -> None:
    """每小时拉一次远程功能开关（`control-v*` Release）。

    节奏刻意与前端 `update_service.dart` 的 1 小时更新检查对齐：GitHub 匿名
    API 限流是 60 次/小时/IP，多开一个更密的定时器只会把额度耗在同一个接口上。
    任何异常都吞掉——定时器不该因为一次断网就退出。
    """
    while True:
        try:
            result = await asyncio.to_thread(remote_gates.refresh)
            if result["applied"]:
                logger.info(f"远程功能开关已应用：rev={result['rev']}")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning(f"远程功能开关拉取失败: {e}")
        await asyncio.sleep(3600)


@app.on_event("shutdown")
async def _shutdown():
    if _gate_task is not None:
        _gate_task.cancel()
    await monitor.stop()


# ---------- 请求 / 响应模型 ----------
class LoginRequest(BaseModel):
    username: str
    password: str
    # 登录入口：jw（教务系统直连，默认）/ cas（统一身份认证）/ vruc（传统）
    mode: str = DEFAULT_MODE
    # 验证码：CAS 必填；教务系统直连仅在触发风控时需要
    captcha: str = ""
    # 验证码会话 id（由 /api/login/captcha 返回，用于复用同一个 HTTP 会话）
    captcha_id: str = ""


class LoginResponse(BaseModel):
    success: bool
    message: str = ""
    mode: str = DEFAULT_MODE
    # 是否需要验证码（前端据此弹出验证码输入框）
    captcha_required: bool = False


class CaptchaRequest(BaseModel):
    mode: str = DEFAULT_MODE


class CaptchaResponse(BaseModel):
    captcha_id: str
    mode: str
    # data:image/jpeg;base64,... 形式的图片
    image: str
    width: int = 60
    height: int = 20


class SettingsUpdate(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None
    remember_me: Optional[bool] = None
    login_mode: Optional[str] = None
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


class ForwarderConfigUpdate(BaseModel):
    bark: Optional[dict] = None
    meow: Optional[dict] = None
    ntfy: Optional[dict] = None


class DeveloperLoginRequest(BaseModel):
    """开发者登录请求：对应 UI 上仅有的三个标签。

    - `mng_id`  → `LoginMngID`（管理者编号，命中内置注册表）
    - `account` → `Account`（GitHub 账号名）
    - `token`   → `Password`（GitHub 令牌；GitHub 没有账号密码换令牌的 API）
    """

    mng_id: str = ""
    account: str = ""
    token: str = ""


class FlagUpdateRequest(BaseModel):
    name: str
    value: bool


class GateUpdateRequest(BaseModel):
    # 功能组开关（Flag-1xxx）；单条与批量共用同一模型，批量走 gates 字段。
    id: str = ""
    value: bool = True
    gates: Optional[dict[str, bool]] = None


class GatePublishRequest(BaseModel):
    """签发一条远程开关指令（写进 `control-v<rev>` Release）。"""

    # 留空则自动取「已应用 rev + 1」
    rev: int = 0
    # 要下发的覆盖项；空字典表示"撤销全部远程覆盖"
    gates: dict[str, bool] = {}
    # 留空则自动生成当前时间
    issued_at: str = ""
    # 发布用的 PAT；留空复用登录时存入系统凭据的令牌
    github_token: str = ""
    # 是否真的推到 GitHub；false 只返回签名块供人工核对
    push: bool = True


class NoticePublishRequest(BaseModel):
    channel: str
    title: str = ""
    body: str = ""


_DEV_REPO = "MaoRM93/GradeMonitor-for-RUC"


def _build_notice_block(kind: str, tag: str, body: str) -> str:
    """用新版发布密钥签署通知正文。"""
    from backend.storage.signing_keys import release_private_key
    digest = hashlib.sha256(body.strip().encode("utf-8")).hexdigest()
    payload = f"gm-notice-v1\nkind={kind}\ntag={tag}\nsha256={digest}\n"
    sig = base64.b64encode(release_private_key().sign(payload.encode("utf-8"))).decode("ascii")
    return f"```text\n{payload}sig={sig}\n```"

# 这些编号承载入口、完整性或关键数据能力。按产品约定仅展示为灰色状态，
# 不允许通过开发者面板、本地 API 或远程控制指令修改。
_LOCKED_GATE_IDS = frozenset({
    "Flag-1051", "Flag-1042", "Flag-1070", "Flag-1071", "Flag-1085",
    "Flag-1084", "Flag-1063", "Flag-1066", "Flag-1060", "Flag-1074",
    "Flag-1001",
})


def _reject_locked_gates(gates: list[str]) -> None:
    locked = sorted(set(gates) & _LOCKED_GATE_IDS)
    if locked:
        raise HTTPException(status_code=400, detail=f"受保护 Flag 不允许修改：{', '.join(locked)}")


def _require_developer() -> None:
    """开发者操作鉴权：本机必须存有一个通过 GitHub 校验的开发者身份。

    历史沿革（值得记下来，因为踩过两次坑）：

      1. 最初只看进程内存里的 `_developer_unlocked`。但 `/api/developer/status`
         返回的是「内存 or settings.json 的 developer_options_enabled」，
         于是重启后设置页照旧显示面板、点任何按钮却全 403。
      2. 于是改成「内存 or 持久化标记」都算通过。这修好了可见性，但把门禁
         建立在 settings.json 的明文布尔值上——那是本地文件，谁都能改成 true，
         等于没有门禁。同时 `GRADEMONITOR_DEVELOPER_PASSWORD` 从来没有注入点
         （前端拉起后端时只注入 APP_PATH 与 API_TOKEN），发行版解锁恒 503。
      3. 现在（本次改造）：唯一判据是 `developer_auth.is_authenticated()`，
         即系统钥匙串 / DPAPI 里存着一个**用 GitHub API 验证过归属**的令牌，
         且其 login 命中内置管理者注册表。settings.json 不再参与鉴权。

    这样即使源码公开，别人改 `developer_options_enabled` 也进不来——他缺的是
    那个只属于作者的 GitHub 令牌。
    """
    if developer_auth.is_authenticated():
        return
    raise HTTPException(status_code=403, detail="开发者选项尚未解锁")


def _gate_closed(gid: str) -> bool:
    """功能组开关是否被远程关闭（Flag-1xxx）。"""
    return not gate_enabled(gid)


def _require_gate(gid: str, feature: str) -> None:
    """功能组闸门：该功能已被远程下线时拒绝服务。

    静默语义：前端本就不该渲染入口，这里只是兜底——即便有人绕过 UI 直接
    调接口，也不会拿到数据。文案刻意简短，不暴露"被远程禁用"这件事。
    """
    if _gate_closed(gid):
        logger.info(f"功能组 {gid}（{feature}）已关闭，拒绝请求")
        raise HTTPException(status_code=403, detail=f"{feature}当前不可用")


# ---------- API 端点 ----------


@app.get("/")
async def root():
    return {"status": "ok", "service": "GradeMonitor Backend"}


# ---------- 验证码会话 ----------
#
# 验证码必须与"取它的那个 HTTP 会话"绑定：CAS 每次 GET 登录页都会刷新
# execution，教务系统直连也把验证码存在服务端会话里。所以这里用
# captcha_id 把 Session 暂存下来，登录时复用同一个 Session。

_captcha_sessions: dict[str, dict] = {}
_CAPTCHA_TTL = 180  # 秒


def _purge_captcha_sessions() -> None:
    """清掉过期的验证码会话，防止长期占内存"""
    now = time.time()
    for key in [
        k for k, v in _captcha_sessions.items() if now - v["created_at"] > _CAPTCHA_TTL
    ]:
        entry = _captcha_sessions.pop(key, None)
        if entry:
            try:
                entry["session"].close()
            except Exception:
                pass


def _pop_captcha_session(captcha_id: str):
    """取出并移除验证码会话"""
    _purge_captcha_sessions()
    entry = _captcha_sessions.pop(captcha_id, None)
    if not entry:
        return None
    return entry["session"]


@app.post("/api/login/captcha", response_model=CaptchaResponse)
async def login_captcha(req: CaptchaRequest):
    """获取登录验证码图片

    CAS 统一认证强制需要验证码；教务系统直连一般不需要（风控时才要）。
    返回 base64 内联图片，前端直接显示，无需再发一次请求。
    """
    _require_gate("Flag-1085", "验证码")
    import base64 as b64
    import uuid

    mode = normalize_mode(req.mode)
    _purge_captcha_sessions()

    try:
        if mode == "cas":
            session = cas_login.new_session()
            raw, _login_url = cas_login.fetch_captcha(session)
            width, height = 60, 20
        else:
            session = jw_login.new_session()
            raw = jw_login.fetch_captcha(session)
            width, height = 60, 20
    except Exception as e:
        logger.error(f"获取验证码失败 (mode={mode}): {e}")
        raise HTTPException(status_code=500, detail=f"获取验证码失败: {e}")

    captcha_id = uuid.uuid4().hex
    _captcha_sessions[captcha_id] = {
        "session": session,
        "mode": mode,
        "created_at": time.time(),
    }

    logger.info(f"已下发验证码 (mode={mode}, id={captcha_id[:8]})")
    return CaptchaResponse(
        captcha_id=captcha_id,
        mode=mode,
        image="data:image/jpeg;base64," + b64.b64encode(raw).decode("ascii"),
        width=width,
        height=height,
    )


@app.get("/api/login/modes")
async def login_modes():
    """返回可用的登录入口（前端欢迎页据此渲染选项）

    顺序即推荐优先级：教务系统直连（默认）→ CAS → 传统 v.ruc。
    被功能组关掉的入口不会出现在列表里（静默下线，前端无需改动）。
    """
    from backend.auth.login import MODE_CAS, MODE_JW, MODE_VRUC

    mode_gates = {
        MODE_JW: "Flag-1080",
        MODE_CAS: "Flag-1081",
        MODE_VRUC: "Flag-1082",
    }
    disabled_modes = {m for m, gid in mode_gates.items() if _gate_closed(gid)}

    all_modes = [
        {
            "id": "jw",
            "name": "教务系统",
            "description": "无需验证码，登录最快，推荐使用",
            "needs_captcha": False,
            "recommended": True,
        },
        {
            "id": "cas",
            "name": "CAS 统一身份验证",
            "description": "学校统一认证平台，需要输入验证码；登录后可 7 天免登录",
            "needs_captcha": True,
            "recommended": False,
        },
        {
            "id": "vruc",
            "name": "传统登录",
            "description": "旧版登录方式，官方即将停止支持",
            "needs_captcha": False,
            "recommended": False,
        },
    ]
    modes = [m for m in all_modes if m["id"] not in disabled_modes]

    # 默认入口也下线时，退到列表里的第一个；全都下线则保持原默认（前端会拿到空列表）
    default_mode = DEFAULT_MODE
    if default_mode in disabled_modes:
        default_mode = modes[0]["id"] if modes else DEFAULT_MODE

    return {"default": default_mode, "modes": modes}


@app.get("/api/session/status")
async def session_status():
    """检查本地保存的登录会话是否还能直接使用（免登录）"""
    _require_gate("Flag-1083", "会话恢复")
    import requests as req_lib

    session = req_lib.Session()
    session.trust_env = False
    try:
        ok = try_restore_session(session)
        payload = session_store.load() or {}
        return {
            "available": bool(ok),
            "login_mode": payload.get("login_mode", ""),
        }
    finally:
        session.close()


@app.post("/api/login", response_model=LoginResponse)
async def login(req: LoginRequest):
    mode = normalize_mode(req.mode)
    # 该登录入口被功能组下线时，直接按"方式不可用"拒绝（不暴露远程开关）
    _require_gate(
        {"jw": "Flag-1080", "cas": "Flag-1081", "vruc": "Flag-1082"}.get(mode, "Flag-1080"),
        "该登录方式",
    )

    # 需要验证码的入口：优先复用前端取码时的那个会话（验证码与会话绑定）
    session = None
    if req.captcha_id:
        session = _pop_captcha_session(req.captcha_id)
        if session is None:
            logger.warning("验证码已过期或不存在，重新建立会话")

    if session is None:
        session = cas_login.new_session() if mode == "cas" else jw_login.new_session()

    try:
        actual = login_by_mode(
            session,
            req.username,
            req.password,
            mode=mode,
            captcha=req.captcha,
        )
        logger.info(f"用户 {req.username} 登录成功（方式={actual}）")
        return LoginResponse(success=True, message="登录成功", mode=actual)
    except LoginError as e:
        # 失败已经分类（凭据错误 / 验证码 / 维护中 / 网络不通），把 kind 透给前端，
        # 前端按 kind 显示对应文案；需要验证码时前端据此弹出输入框。
        logger.error(f"用户 {req.username} 登录失败 [{e.kind}]: {e}")
        raise HTTPException(
            status_code=401,
            detail={
                "kind": e.kind,
                "message": e.user_message,
                "detail": str(e),
                "captcha_required": e.kind
                in (KIND_CAPTCHA_REQUIRED, KIND_CAPTCHA_INVALID),
                "mode": mode,
            },
        )
    except Exception as e:
        logger.error(f"用户 {req.username} 登录失败: {e}")
        raise HTTPException(status_code=401, detail=str(e))
    finally:
        try:
            session.close()
        except Exception:
            pass


@app.get("/api/grades")
async def get_grades():
    """获取成绩列表（从内存缓存，不从文件/API读取）"""
    _require_gate("Flag-1070", "成绩数据")
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
    _require_gate("Flag-1072", "最新动态")
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
    _require_gate("Flag-1071", "排名数据")
    global _rank_cache
    if not _rank_cache:
        return {"data": None, "message": "暂无排名数据"}
    logger.debug(f"返回缓存排名: pm={_rank_cache.get('pm')}")
    return {"data": _rank_cache}


@app.get("/api/settings")
async def get_settings():
    """返回设置（**不含密码**，仅 has_password 标记）。

    密码保存在系统安全存储（钥匙串/DPAPI）中，前端不再需要取值；
    给出 has_password 便于设置页显示"已保存密码"状态。
    """
    return public_settings()


@app.post("/api/settings")
async def update_settings(update: SettingsUpdate):
    current = load_settings()
    changed = {k: v for k, v in update.dict(exclude_none=True).items() if v is not None}

    # 轮询间隔绝不能让开发者工具或直接 API 请求写入 0/负数；否则在关闭
    # 随机间隔时会触发 asyncio.sleep(负数) 的紧循环。
    if "interval_seconds" in changed:
        interval = int(changed["interval_seconds"])
        if not 60 <= interval <= 86400:
            raise HTTPException(status_code=400, detail="轮询间隔必须在 60 至 86400 秒之间")

    # 密码单独处理：只有前端显式传了非空 password 才更新；传空串表示清除。
    # 未传（None/exclude_none 后不存在）则保持安全存储中的既有密码不变。
    password_change = changed.pop("password", None)

    for key, val in changed.items():
        current[key] = val
    if password_change is not None:
        current["password"] = password_change

    save_settings(current)
    logger.info(f"设置已更新: {list(changed.keys())}{' + password' if password_change is not None else ''}")

    # 开机自启动设置变更时，同步到系统（macOS 登录项 / Windows 注册表）
    if "auto_start" in changed:
        try:
            from backend.utils.startup import set_startup_enabled
            set_startup_enabled(current["auto_start"])
            logger.info(f"开机自启动: {'已启用' if current['auto_start'] else '已禁用'}")
        except Exception as e:
            logger.warning(f"开机自启动设置失败: {e}")

    # 响应同样不包含密码
    return {"success": True, "settings": public_settings()}


@app.get("/api/notification/forwarders")
async def get_forwarders():
    _require_gate("Flag-1030", "通知转发")
    return public_config()


@app.post("/api/notification/forwarders")
async def update_forwarders(update: ForwarderConfigUpdate):
    _require_gate("Flag-1030", "通知转发")
    return {"success": True, "forwarders": save_config(update.dict(exclude_none=True))}


@app.post("/api/notification/forwarders/{channel}/test")
async def test_forwarder_channel(channel: str):
    _require_gate("Flag-1033", "通道测试")
    return test_forwarder(channel)

class CurriculumOpenRequest(BaseModel):
    # 可选：显式指定年级（开发者开关 1.1 解锁全部年级时前端会传）。
    # 不传 → None → 沿用原来的账号匹配逻辑，老前端逐字节兼容。
    grade: Optional[str] = None


@app.post("/api/curriculum/open")
async def open_current_curriculum(req: Optional[CurriculumOpenRequest] = None):
    _require_gate("Flag-1075", "培养方案查看器")
    grade = open_curriculum(req.grade if req else None)
    return {"success": True, "grade": grade, "message": f"已在浏览器中打开 {grade} 级培养方案"}

@app.get("/api/curriculum/view/{grade}")
async def view_current_curriculum(grade: str, access: str = ""):
    _require_gate("Flag-1075", "培养方案查看器")
    return view_curriculum(grade, access)


@app.get("/api/developer/status")
async def developer_status():
    """开发者登录状态（不含令牌本身）。

    `unlocked` 的唯一来源是凭据存储里那个通过 GitHub 校验过的身份。
    不再有任何 settings.json 布尔值参与判定——那是本地明文文件，
    谁都能改成 true，把它当门禁等于没有门禁。
    """
    return developer_auth.session_payload()


@app.post("/api/developer/login")
async def developer_login(req: DeveloperLoginRequest):
    """用 GitHub 身份登录开发者模式。

    三个字段对应 UI 上仅有的三个标签：LoginMngID / Account / Password。
    校验失败统一 401 + 同一句文案，不做账号探测 oracle。
    """
    try:
        result = developer_auth.verify_and_store(req.mng_id, req.account, req.token)
    except developer_auth.DeveloperAuthError as e:
        raise HTTPException(status_code=e.status_code, detail=e.message)
    return result


@app.post("/api/developer/logout")
async def developer_logout():
    """退出开发者模式：清除系统凭据存储里的令牌与身份。"""
    _require_developer()
    developer_auth.logout()
    return {"success": True, "message": "已退出开发者模式"}


@app.get("/api/developer/flags")
async def developer_get_flags():
    """读取全部开发者开关。

    刻意**不**调用 `_require_developer()`：方案计算页等业务页面要读开关来
    决定渲染哪些入口，让它们先解锁开发者口令是没道理的。该端点仍在本地
    API 令牌中间件保护范围内（未列入 security._PUBLIC_PATHS）。
    """
    return {"flags": load_flags()}


@app.post("/api/developer/flags")
async def developer_set_flag(req: FlagUpdateRequest):
    """写入单个开发者开关；未知开关名一律 400，避免脏键污染文件。"""
    _require_developer()
    if req.name not in DEFAULT_FLAGS:
        raise HTTPException(status_code=400, detail="未知的开关名")
    return {"success": True, "flags": set_flag(req.name, req.value)}


# ---------- 功能组开关（Flag-1xxx） ----------
#
# 与上面的 /api/developer/flags 是两套东西：
#   - flags 是开发者面板上的调谐按钮（1.x / 2.x），语义偏调试；
#   - gates 是产品功能组的下线闸门（Flag-1xxx），每一个都对应真实业务代码。
# 读取接口同样不要求开发者解锁（业务页面要按开关决定渲染），写入要求解锁。


@app.get("/api/features")
async def list_features():
    """功能组注册表 + 当前开关状态。

    不调用 `_require_developer()`：业务页面（仪表板/成绩单/方案计算…）要在
    渲染前读开关决定显示哪些块，让它们先解锁开发者口令是没道理的。
    该端点仍在本地 API 令牌中间件保护范围内。
    """
    return {"features": registry_payload()}


@app.post("/api/developer/features")
async def developer_set_feature(req: GateUpdateRequest):
    """写入功能组开关。

    两种用法：
      - 单条：`{"id": "Flag-1001", "value": false}`
      - 批量：`{"gates": {"Flag-1001": false, "Flag-1010": true}}`
    未知编号一律 400（与 flags 一致），避免脏键污染文件。
    """
    _require_developer()

    if req.gates is not None:
        unknown = [gid for gid in req.gates if gid not in DEFAULT_GATES]
        if unknown:
            raise HTTPException(
                status_code=400,
                detail=f"未知的功能组编号：{', '.join(sorted(unknown))}",
            )
        _reject_locked_gates(list(req.gates))
        current = load_gates()
        for gid, value in req.gates.items():
            current[gid] = bool(value)
        return {"success": True, "gates": save_gates(current)}

    if req.id not in DEFAULT_GATES:
        raise HTTPException(status_code=400, detail="未知的功能组编号")
    _reject_locked_gates([req.id])
    return {"success": True, "gates": set_gate(req.id, req.value)}


@app.post("/api/developer/gates/publish")
async def developer_publish_gates(req: GatePublishRequest):
    """签发（并可选推送）一条远程功能开关指令。

    指令写进独立的 `control-v<rev>` Release 频道，正文是 Ed25519 签名块。
    客户端拉取后验签 + 校验 rev 单调，通过才应用。控制私钥仅在开发机
    macOS 钥匙串中，所以即使仓库写权限外泄，也无法签出有效指令。

    `push=false` 时只返回签名块供 UI 预览，不占用版本号、不改动本机状态。
    """
    _require_developer()

    unknown = [gid for gid in req.gates if gid not in DEFAULT_GATES]
    if unknown:
        raise HTTPException(
            status_code=400,
            detail=f"未知的功能组编号：{', '.join(sorted(unknown))}",
        )
    _reject_locked_gates(list(req.gates))

    current = remote_gates.load_remote()
    rev = int(req.rev) if req.rev > 0 else current["rev"] + 1
    if rev <= current["rev"]:
        raise HTTPException(
            status_code=400,
            detail=f"rev 必须大于已应用的 {current['rev']}",
        )

    # UI 只提交本次改动；对外发布的签名包仍是完整快照，使从未拉取过
    # 配置的客户端只要拿到最新版即可恢复全部远程覆盖。空字典是显式撤回。
    published_gates = {} if not req.gates else dict(current["gates"])
    published_gates.update(req.gates)

    issued_at = req.issued_at.strip() or time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
    )
    try:
        block = remote_gates.build_block(rev, published_gates, issued_at)
    except FileNotFoundError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        logger.error(f"签发远程开关失败: {e}")
        raise HTTPException(status_code=500, detail=f"签发失败：{e}")

    if not req.push:
        return {"success": True, "rev": rev, "block": block, "pushed": False}

    token = (req.github_token or "").strip() or developer_auth.developer_token()
    if not token:
        raise HTTPException(status_code=400, detail="请输入 GitHub Fine-grained PAT")

    tag = f"{remote_gates.TAG_PREFIX}{rev}"
    payload = {
        "tag_name": tag,
        "name": f"功能开关 rev {rev}",
        "body": block,
        "draft": False,
        "prerelease": True,
    }
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
    }
    base = f"https://api.github.com/repos/{_DEV_REPO}/releases"
    existing = requests.get(f"{base}/tags/{tag}", headers=headers, timeout=15)
    if existing.status_code == 200:
        response = requests.patch(
            f"{base}/{existing.json()['id']}", headers=headers, json=payload, timeout=15
        )
    else:
        response = requests.post(base, headers=headers, json=payload, timeout=15)
    if not response.ok:
        raise HTTPException(status_code=502, detail=f"GitHub 发布失败：{response.status_code}")

    # 发布成功后才落地完整快照；发布失败时绝不改变本机功能状态。
    remote_gates.save_remote(rev, published_gates)
    return {
        "success": True,
        "rev": rev,
        "tag": tag,
        "block": block,
        "pushed": True,
        "message": f"已下发功能开关 rev {rev}",
    }


@app.post("/api/developer/notices/publish")
async def developer_publish_notice(req: NoticePublishRequest):
    """通过开发者 UI 签名并发布广播、蓝屏或红屏通知。"""
    _require_developer()
    channel, body, title = req.channel.strip(), req.body.strip(), req.title.strip()
    mapping = {
        "Default_Notice": ("broadcast", f"114.{int(time.time() * 1000)}"),
        "Important (BL)": ("blue", "developer-alert"),
        "Disable (RE)": ("red", "service-suspension"),
    }
    if channel not in mapping:
        raise HTTPException(status_code=400, detail="未知通知渠道")
    if not body:
        raise HTTPException(status_code=400, detail="正文不能为空")
    if channel != "Default_Notice":
        title = ""
    elif not title:
        raise HTTPException(status_code=400, detail="默认广播需要填写标题")
    kind, tag = mapping[channel]
    full_body = f"{body}\n\n{_build_notice_block(kind, tag, body)}"
    token = developer_auth.developer_token()
    if not token:
        raise HTTPException(status_code=400, detail="开发者令牌不可用，请重新登录")
    base = f"https://api.github.com/repos/{_DEV_REPO}/releases"
    headers = {"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}"}
    payload = {"tag_name": tag, "name": title or tag, "body": full_body, "draft": False, "prerelease": True}
    try:
        existing = requests.get(f"{base}/tags/{tag}", headers=headers, timeout=15)
        response = requests.patch(f"{base}/{existing.json()['id']}", headers=headers, json=payload, timeout=15) if existing.status_code == 200 else requests.post(base, headers=headers, json=payload, timeout=15)
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"GitHub 发布失败：{e}")
    if not response.ok:
        raise HTTPException(status_code=502, detail=f"GitHub 发布失败：{response.status_code}")
    return {"success": True, "tag": tag, "message": "通知已发送"}


@app.get("/api/monitor/status")
async def get_monitor_status():
    _require_gate("Flag-1001", "监控")
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
    _require_gate("Flag-1001", "监控")
    try:
        await monitor.start()
        return {"success": True, "message": "监控已启动"}
    except Exception as e:
        logger.error(f"启动监控失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/monitor/stop")
async def stop_monitor():
    _require_gate("Flag-1001", "监控")
    try:
        await monitor.stop()
        return {"success": True, "message": "监控已停止"}
    except Exception as e:
        logger.error(f"停止监控失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/monitor/restart")
async def restart_monitor():
    _require_gate("Flag-1001", "监控")
    try:
        await monitor.restart()
        return {"success": True, "message": "监控已重启"}
    except Exception as e:
        logger.error(f"重启监控失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/logout")
async def logout():
    """退出登录：停掉监控、清除已保存的凭据，回到未登录状态。

    只清除**凭据**（学号 + 钥匙串/DPAPI 里的密码）与欢迎向导完成标记，
    不删除已缓存的成绩与排名数据——本地数据属于用户，退出登录不该连带清空。
    需要清空数据请用 /api/dev/clear-all-data。
    """
    try:
        # 先停监控，避免凭据被清掉后监控线程拿着空密码反复请求教务系统
        if monitor.is_running:
            await monitor.stop()
            logger.info("退出登录：监控已停止")
    except Exception as e:
        logger.warning(f"退出登录时停止监控失败: {e}")

    current = load_settings()
    current["username"] = ""
    # 显式传空串 → save_settings 会走 clear_password() 清除安全存储
    current["password"] = ""
    current["remember_me"] = False
    # 重置欢迎向导标记：下次登录时重新走一遍引导
    current["welcome_completed"] = False
    save_settings(current)

    # 清掉落盘的登录会话（否则下次启动会被"免登录恢复"直接绕过登录页）
    try:
        session_store.clear()
        logger.info("退出登录：本地登录会话已清除")
    except Exception as e:
        logger.warning(f"清除登录会话失败: {e}")

    logger.info("退出登录：凭据已清除")

    return {"success": True, "message": "已退出登录", "settings": public_settings()}


@app.post("/api/notification/test")
async def test_notification():
    _require_gate("Flag-1053", "通知")
    try:
        send_test_notification()
        logger.info("测试通知已发送")
        return {"success": True, "message": "测试通知已发送"}
    except Exception as e:
        logger.error(f"测试通知失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/notification/preview")
async def preview_notification(mode: str = "详细"):
    _require_gate("Flag-1053", "通知")
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
    _require_gate("Flag-1002", "立即查询")
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
    # WebSocket 鉴权：浏览器/第三方进程无法伪造自定义头，因此这里同时
    # 接受 Header 与 query 参数（前端用 Header，尽力而为）。
    provided = websocket.headers.get(TOKEN_HEADER) or websocket.query_params.get("token", "")
    if not header_token(provided):
        logger.warning("拒绝未授权的 WebSocket 连接")
        await websocket.close(code=1008)
        return

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
