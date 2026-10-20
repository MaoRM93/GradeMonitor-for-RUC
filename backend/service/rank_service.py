# backend/service/rank_service.py
"""
排名查询服务
"""
import requests
from typing import Any, Optional

from backend.auth.login import login_and_bind_jw
from backend.utils.logger import get_logger

logger = get_logger(__name__)

# 学期过滤兜底列表：2026-08 抓包验证可用（当时学生全部已出分学期）。
# 主策略是动态推导（storage.cache.derive_semesters_from_local_grades：
# 从学生本人成绩的 cjlrxq 收集真实学期代码）。真机验证结论：排名接口
# 对学期代码做字典校验，传入字典外的代码会被整单拒绝
# （eywxt.public.query.error，2026-10-20 实测）——所以不能像当初设想的
# 那样枚举 2010→2099 全量学期，只能传真实出现过的代码。
_FALLBACK_SEMESTERS = (
    "2025-2026-2,2025-2026-1,"
    "2024-2025-4,2024-2025-2,2024-2025-1"
)


def fetch_rank(
    session: requests.Session,
    semesters: Optional[list[str]] = None,
) -> Optional[dict[str, Any]]:
    """
    调用排名接口，获取所有学期的专业排名和班级排名

    Args:
        session: 已经过 OAuth 认证的 requests.Session
        semesters: 参与累计计算的学期代码列表（来自学生本人成绩的
            cjlrxq 去重集合，含小学期）。None/空时使用历史抓包列表
            （_FALLBACK_SEMESTERS）。

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

    # 学期过滤：优先用学生本人成绩推导的真实学期代码（动态、含小学期）；
    # 未提供或为空时回退历史抓包列表（见 _FALLBACK_SEMESTERS 注释）
    if semesters:
        codes = sorted(set(semesters), reverse=True)
        semester_filter = ",".join(codes)
    else:
        semester_filter = _FALLBACK_SEMESTERS
        codes = semester_filter.split(",")
    payload = {
        "jczy013id": semester_filter,
        "kclbcode": "",
        "jczy010id": [],
        "jczy013idList": [],
    }

    logger.debug(
        f"Rank query semester filter: {len(codes)} terms "
        f"({codes[-1]} … {codes[0]})"
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

    def fetch_latest_rank(
        self, semesters: Optional[list[str]] = None
    ) -> Optional[dict[str, Any]]:
        """获取最新排名信息

        Args:
            semesters: 参与累计计算的学期代码列表（来自学生本人成绩的
                cjlrxq 去重集合）。None/空时使用历史抓包 5 学期列表；
                动态列表被教务接口拒绝时自动回退该列表重试一次。
        """
        session = self._create_session()
        try:
            if semesters:
                try:
                    return fetch_rank(session, semesters=semesters)
                except Exception as e:
                    logger.warning(
                        f"动态学期列表查询被拒({e})，回退历史列表重试"
                    )
            return fetch_rank(session)
        finally:
            session.close()
