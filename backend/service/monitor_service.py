# backend/service/monitor_service.py
"""
自动监控服务

使用 asyncio 定时查询成绩/排名，与本地缓存对比，检测变化后通过回调广播事件。
"""
import asyncio
import random
from datetime import datetime, time as dt_time
from typing import Awaitable, Callable

from backend.service.grade_service import GradeService
from backend.service.rank_service import RankService
from backend.service.notification_service import (
    send_grades_notification,
    send_rank_notification,
)
from backend.storage.cache import (
    diff_grades,
    derive_semesters_from_local_grades,
    load_local_grades,
    load_local_ranks,
    save_local_grades,
    save_local_ranks,
    load_total_query_count,
    increment_query_count,
    reset_query_count,
)
from backend.storage.settings import load_settings
from backend.utils.logger import get_logger

logger = get_logger(__name__)

# 回调类型: async func that receives event dict
EventListener = Callable[[dict], Awaitable[None]]


class MonitorService:
    """
    后台监控服务

    用法:
        monitor = MonitorService()
        monitor.add_listener(my_handler)
        await monitor.start()
    """

    def __init__(self) -> None:
        self._running = False
        self._task: asyncio.Task | None = None
        self._listeners: list[EventListener] = []
        self.last_query_at: datetime | None = None
        self._on_grades_updated: Callable[[dict], None] | None = None
        self._on_rank_updated: Callable[[dict], None] | None = None
        self._on_refresh_cache: Callable[[], None] | None = None

    # ---------- 事件订阅 ----------

    def add_listener(self, callback: EventListener) -> None:
        """注册事件监听器"""
        self._listeners.append(callback)

    def remove_listener(self, callback: EventListener) -> None:
        """移除事件监听器"""
        if callback in self._listeners:
            self._listeners.remove(callback)

    def set_cache_callbacks(
        self,
        on_grades_updated: Callable[[dict], None],
        on_rank_updated: Callable[[dict], None],
        on_refresh_cache: Callable[[], None] | None = None,
    ) -> None:
        """设置缓存更新回调（由 app.py 调用）"""
        self._on_grades_updated = on_grades_updated
        self._on_rank_updated = on_rank_updated
        self._on_refresh_cache = on_refresh_cache

    async def _broadcast(self, event: dict) -> None:
        """向所有监听器广播事件"""
        for listener in self._listeners:
            try:
                await listener(event)
            except Exception:
                pass

    # ---------- 生命周期 ----------

    async def start(self) -> None:
        """启动监控循环"""
        if self._running:
            return
        self._running = True
        self._task = asyncio.create_task(self._loop())
        logger.info("监控服务已启动")

    async def stop(self) -> None:
        """停止监控循环"""
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        logger.info("监控服务已停止")

    async def restart(self) -> None:
        """重启监控（设置变更后调用）"""
        await self.stop()
        await self.start()

    @property
    def is_running(self) -> bool:
        return self._running

    # ---------- 监控主循环 ----------

    async def _loop(self) -> None:
        """主循环：定时查询 → 对比 → 广播"""
        while self._running:
            try:
                settings = load_settings()
                username = settings.get("username", "")
                password = settings.get("password", "")

                # 无凭据时跳过
                if not username or not password:
                    logger.info("[自动监控] 无登录凭据，等待 30s 后重试")
                    await asyncio.sleep(30)
                    continue

                # 时间窗口检查
                start = settings.get("start_time", "08:00")
                end = settings.get("end_time", "22:00")
                if not self._in_time_window(start, end):
                    now_str = datetime.now().strftime("%H:%M")
                    logger.info(f"[自动监控] 当前时间 {now_str} 不在监控时段 {start}-{end} 内，等待 60s")
                    await asyncio.sleep(60)
                    continue

                # 成绩监控
                queried = False
                is_simple = settings.get("notify_mode", "详细") == "简洁"
                logger.info(
                    f"[自动监控] 开始检测: auto_monitor={settings.get('auto_monitor_enabled')}, "
                    f"rank_monitor={settings.get('rank_monitor_enabled')}, "
                    f"interval={settings.get('interval_seconds', 300)}s"
                )
                if settings.get("auto_monitor_enabled"):
                    await self._check_grades(username, password, is_simple)
                    queried = True

                # 排名监控
                if settings.get("rank_monitor_enabled"):
                    await self._check_rank(username, password, is_simple)
                    queried = True

                if queried:
                    increment_query_count()

                self.last_query_at = datetime.now()

                # 等待下一轮
                # 安全模式（默认开启）：每轮结束后在设定间隔 ±100 秒内重新
                # 随机取等待时间，降低固定间隔轮询被风控识别的风险
                interval = settings.get("interval_seconds", 300)
                if settings.get("random_interval_enabled", True):
                    wait_seconds = max(
                        10, random.randint(interval - 100, interval + 100)
                    )
                    logger.info(
                        f"[自动监控] 安全模式生效，本次实际等待 {wait_seconds}s"
                    )
                else:
                    wait_seconds = interval
                await asyncio.sleep(wait_seconds)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"循环异常: {e}", exc_info=True)
                await asyncio.sleep(60)

    # ---------- 成绩检查 ----------

    async def _check_grades(self, username: str, password: str, is_simple: bool = False) -> None:
        """查询成绩并与本地JSON文件对比（允许手动编辑JSON触发通知）"""
        try:
            # 先从JSON文件重新加载，确保与内存缓存同步（允许用户手动编辑JSON）
            if self._on_refresh_cache:
                self._on_refresh_cache()

            old_grades = load_local_grades()
            if old_grades is None:
                # JSON 彻底无法解析：跳过本轮，避免以空基准误报"全部课程新增"
                logger.warning("[自动监控] 本地JSON损坏且无法修复，跳过本轮成绩对比")
                return
            logger.info(f"[自动监控] 本地JSON中有 {len(old_grades)} 门课程")

            service = GradeService(username, password)
            result = service.fetch_grade_json()

            new_grades: dict = {}
            for course in result.get("data", []):
                kth = course.get("kth")
                if kth:
                    new_grades[kth] = course
            logger.info(f"[自动监控] 服务器返回 {len(new_grades)} 门课程")

            # 对比差异
            new_courses, changed_courses = diff_grades(old_grades, new_grades)
            logger.info(
                f"[自动监控] 对比结果: 新增 {len(new_courses)} 门, 变动 {len(changed_courses)} 门"
            )

            # 保存最新数据
            if self._on_grades_updated:
                self._on_grades_updated(new_grades)
            else:
                save_local_grades(new_grades)

            # 有变化则发通知（首次也按统一模板通知）
            if new_courses or changed_courses:
                # 发送系统通知
                all_changed = new_courses + changed_courses
                send_grades_notification(
                    new_count=len(new_courses),
                    changed_count=len(changed_courses),
                    course_details=all_changed,
                    is_simple=is_simple,
                )
                # 广播 WebSocket 事件
                await self._broadcast({
                    "type": "grades_changed",
                    "new_count": len(new_courses),
                    "changed_count": len(changed_courses),
                    "total": len(new_grades),
                    "timestamp": datetime.now().isoformat(),
                })
                logger.info(f"成绩变化: +{len(new_courses)} 新, ~{len(changed_courses)} 变动")

        except Exception as e:
            logger.error(f"成绩检查失败: {e}", exc_info=True)

    # ---------- 排名检查 ----------

    async def _check_rank(self, username: str, password: str, is_simple: bool = False) -> None:
        """查询排名并与本地JSON文件对比（允许手动编辑JSON触发通知）"""
        try:
            # 先从JSON文件重新加载，确保与内存缓存同步
            if self._on_refresh_cache:
                self._on_refresh_cache()

            old_rank = load_local_ranks()
            logger.info(f"[自动监控] 本地排名: pm={old_rank.get('pm') if old_rank else 'None'}")

            service = RankService(username, password)
            new_rank = service.fetch_latest_rank(derive_semesters_from_local_grades())
            if not new_rank:
                logger.info("[自动监控] 服务器未返回排名数据")
                return
            # 通过回调更新内存缓存+文件
            if self._on_rank_updated:
                self._on_rank_updated(new_rank)
            else:
                save_local_ranks(new_rank)

            if old_rank:
                changes = []
                if new_rank.get("pm") != old_rank.get("pm"):
                    changes.append(
                        f"专业排名: {old_rank.get('pm')}/{old_rank.get('countnum')} "
                        f"→ {new_rank.get('pm')}/{new_rank.get('countnum')}"
                    )
                if new_rank.get("bjpm") != old_rank.get("bjpm"):
                    changes.append(
                        f"班级排名: {old_rank.get('bjpm')}/{old_rank.get('bjgms')} "
                        f"→ {new_rank.get('bjpm')}/{new_rank.get('bjgms')}"
                    )

                if changes:
                    # 发送系统通知
                    send_rank_notification(
                        rank_data=new_rank,
                        change_msgs=changes,
                        is_simple=is_simple,
                    )
                    # 广播 WebSocket 事件
                    await self._broadcast({
                        "type": "rank_changed",
                        "changes": changes,
                        "timestamp": datetime.now().isoformat(),
                    })
                    logger.info(f"排名变化: {'; '.join(changes)}")

        except Exception as e:
            logger.error(f"排名检查失败: {e}", exc_info=True)

    # ---------- 时间窗口工具 ----------

    @staticmethod
    def _in_time_window(start_str: str, end_str: str) -> bool:
        """判断当前时间是否在窗口内（含跨天）"""
        try:
            now = datetime.now().time()
            start = dt_time.fromisoformat(start_str)
            end = dt_time.fromisoformat(end_str)
            if start <= end:
                return start <= now <= end
            else:
                return now >= start or now <= end
        except Exception:
            return True


# 全局单例
monitor = MonitorService()
