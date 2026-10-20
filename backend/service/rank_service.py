# backend/service/rank_service.py
"""
排名查询服务
"""
import requests
from typing import Any, Optional

from backend.auth.login import login_and_bind_jw
from backend.utils.logger import get_logger

logger = get_logger(__name__)

# 全量学期代码：2010-2011-1 → 2099-2100-4，每学年含 -1/-2/-3/-4，共 360 项，
# 模块加载时生成一次。排名接口的 jczy013id 是「参与累计排名/绩点计算的学期过滤」：
# 历史版本只写死当时最新的 5 个学期（2024-2025-1 → 2025-2026-2），导致小学期
# （-4，如 2025-2026-4）及之后新学期的成绩不参与累计计算，出现「总绩点差 0.01、
# 班级/专业排名差 1、课程总数正常」的偏差（2026-10 用户反馈并考证实锤）。
# 写死 2010→2099 全量学期，百年内无需维护。学期序号沿用教务系统编码：
# 1=秋季学期，2=春季学期，4=夏季/小学期；-3 暂无实证，按全量覆盖传入
# （若教务接口不接受 -3，冒烟时会报 errorCode≠success，届时退回 1/2/4）。


def _build_semester_list() -> str:
    """生成 2010-2011 至 2099-2100 全部学期代码（降序、逗号分隔）。"""
    codes = []
    for year in range(2099, 2009, -1):  # 学年降序：2099-2100 → 2010-2011
        for term in (4, 3, 2, 1):  # 学期内降序，与历史 payload 顺序一致
            codes.append(f"{year}-{year + 1}-{term}")
    return ",".join(codes)


_ALL_SEMESTERS = _build_semester_list()
_SEMESTER_COUNT = _ALL_SEMESTERS.count(",") + 1


def fetch_rank(session: requests.Session) -> Optional[dict[str, Any]]:
    """
    调用排名接口，获取所有学期的专业排名和班级排名

    Args:
        session: 已经过 OAuth 认证的 requests.Session

    Returns:
        dict | None: 包含专业排名(pm)、班级排名(bjpm)、总人数(countnum)等
    """
    api_url = (
        "https://jw.ruc.edu.cn/resService/jwxtpt/v1/xsd/cjgl_xsxdsq/"
        "professionalRankingQuery"
        "?resourceCode=XSMH0527"
        "&apiCode=jw.xsd.xsdInfo.controller.CjglKccjckController"
        ".professionalRankingQuery"
    )

    # 从 session 中提取 token
    jwt_token = session.cookies.get("token", domain="jw.ruc.edu.cn")
    if not jwt_token:
        logger.error("Missing JWT token in session cookies")
        raise Exception(
            "Missing JWT token in session cookies. "
            "Authentication may have failed."
        )

    # 注入认证头
    session.headers.update({
        "Authorization": f"Bearer {jwt_token}",
        "token": jwt_token,
        "Content-Type": "application/json",
    })

    # 构造请求参数（学期过滤 = 全量学期 2010-2011-1 → 2099-2100-4，见 _ALL_SEMESTERS 注释）
    payload = {
        "jczy013id": _ALL_SEMESTERS,
        "kclbcode": "",
        "jczy010id": [],
        "jczy013idList": [],
    }

    logger.debug(
        f"Rank query semester filter: {_SEMESTER_COUNT} terms "
        f"({_ALL_SEMESTERS[-11:]} … {_ALL_SEMESTERS[:11]})"
    )

    logger.info("Requesting rank data from API (with JWT Bearer)...")
    response = session.post(api_url, json=payload)

    if response.status_code != 200:
        logger.error(f"Rank API request failed with status: {response.status_code}")
        raise Exception(
            f"Rank API request failed with status: "
            f"{response.status_code}. Response: {response.text[:300]}"
        )

    resp_json = response.json()
    if resp_json.get("errorCode") != "success":
        logger.error(f"Rank API returned error: {resp_json.get('errorMessage')}")
        raise Exception(
            f"Rank API returned error: {resp_json.get('errorMessage')}"
        )

    data = resp_json.get("data", [])
    if not data:
        logger.warning("Rank API returned empty data")
        return None

    # 取第一条记录（通常只有一条，包含所有汇总信息）
    rank_info = data[0]
    logger.info(f"Rank data fetched successfully (pm={rank_info.get('pm')}, bjpm={rank_info.get('bjpm')})")
    return {
        "pm": rank_info.get("pm", "N/A"),
        "bjpm": rank_info.get("bjpm", "N/A"),
        "countnum": rank_info.get("countnum", "N/A"),
        "bjgms": rank_info.get("bjgms", "N/A"),
        "sdxf": rank_info.get("sdxf", "N/A"),          # 已取得总学分
        "zjd": rank_info.get("zjd", "N/A"),            # 总学分绩点
        "pjxfjd": rank_info.get("pjxfjd", "N/A"),       # 平均学分绩点
        "ndzy_name": rank_info.get("ndzy_name", "未知专业"),
        "xs_name": rank_info.get("xs_name", "未知姓名"),
        "xh": rank_info.get("xh", "未知学号"),
        "xnxq": rank_info.get("xnxq", "全部学年"),
    }


class RankService:
    """
    排名查询服务封装

    管理 Session 生命周期，提供高层查询接口。
    """

    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password

    def _create_session(self) -> requests.Session:
        """创建并认证一个新的 Session"""
        session = requests.Session()
        session.headers.update({
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36"
            ),
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
        })
        login_and_bind_jw(session, self.username, self.password)
        return session

    def fetch_latest_rank(self) -> Optional[dict[str, Any]]:
        """获取最新排名信息"""
        session = self._create_session()
        try:
            return fetch_rank(session)
        finally:
            session.close()
