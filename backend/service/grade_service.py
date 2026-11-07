# backend/service/grade_service.py
"""
成绩查询服务

使用已认证的 Session 请求教务系统成绩 API，返回结构化数据。
"""
import requests
from typing import Any

from backend.auth.login import (
    background_login_mode,
    create_authenticated_session,
    force_relogin,
)
from backend.utils.logger import get_logger

logger = get_logger(__name__)


def _is_auth_failure(exc: Exception) -> bool:
    """判断异常是否属于"会话在服务端已失效"（可重登恢复）

    教务网关的典型响应：
      HTTP 401，或 HTTP 200 但 errorMessage=security.httpstatu.401.1006
      （The Claim 'sid' value doesn't match the required one.）
    """
    text = str(exc)
    return "401" in text or "sid" in text.lower() or "Unauthorized" in text


def fetch_all_grades(session: requests.Session) -> dict[str, Any]:
    """
    使用已授权的 Session 获取全部成绩列表（自动翻页）

    Args:
        session: 已经过 OAuth 认证的 requests.Session

    Returns:
        dict: { errorCode, errorMessage, data: [...] }
    """
    api_url = (
        "https://jw.ruc.edu.cn/resService/jwxtpt/v1/xsd/cjgl_xsxdsq/findKccjList"
        "?resourceCode=XSMH0526"
        "&apiCode=jw.xsd.xsdInfo.controller.CjglKccjckController.findKccjList"
    )

    jwt_token = session.cookies.get("token", domain="jw.ruc.edu.cn")
    if not jwt_token:
        raise Exception(
            "Missing JWT token in session cookies. "
            "Authentication may have failed."
        )

    # 教务网关（2026-11 起的行为变化）对这两个头是硬要求，缺一不可：
    #   1) Accept: application/json —— 缺失时网关返回 application/xml 包装体
    #      （<errorMessage>success</errorMessage>，没有 data），看起来"成功但 0 门课"；
    #   2) userRoleCode: student —— 缺失时业务层报
    #      security.SysPermissionService.userCurrentRole.isNull，同样拿不到数据。
    # 两者同时存在才返回 errorCode=success + 真实成绩列表。
    session.headers.update({
        "Authorization": f"Bearer {jwt_token}",
        "token": jwt_token,
        "Accept": "application/json",
        "userRoleCode": "student",
    })

    all_courses = []
    page_index = 1
    page_size = 200

    logger.info("Requesting grade data from API (paginated)...")

    while True:
        payload = {
            "pyfa007id": "1",
            "jczy013id": [],
            "fxjczy005id": "",
            "cjckflag": "xsdcjck",
            "kthList": [],
            "page": {
                "pageIndex": page_index,
                "pageSize": page_size,
                "orderBy": '[{"field":"jczy013id","sortType":"asc"}]',
            },
        }

        response = session.post(api_url, json=payload)

        if response.status_code != 200:
            logger.error(f"API request failed at page {page_index}: {response.status_code}")
            raise Exception(
                f"API request failed with status: {response.status_code}. "
                f"Response: {response.text[:300]}"
            )

        resp_json = response.json()

        if resp_json.get("errorMessage") == "security.httpstatu.401.1006":
            logger.error("API returned 401 Unauthorized")
            raise Exception(
                "API returned 401 Unauthorized inside HTTP 200 payload."
            )

        page_data = resp_json.get("data", [])
        if not page_data:
            break

        all_courses.extend(page_data)
        logger.debug(f"Page {page_index}: {len(page_data)} courses (total: {len(all_courses)})")

        # 检查是否还有下一页
        total_pages = resp_json.get("totalPages")
        if total_pages and page_index >= total_pages:
            break
        if len(page_data) < page_size:
            break

        page_index += 1

    logger.info(f"Grade data fetched: {len(all_courses)} courses across {page_index} pages")
    return {
        "errorCode": "success",
        "errorMessage": None,
        "data": all_courses,
    }


class GradeService:
    """
    成绩查询服务封装

    管理 Session 生命周期，提供高层查询接口。
    """

    def __init__(self, username: str, password: str, login_mode: str = ""):
        self.username = username
        self.password = password
        # 未显式指定时用后台安全入口：后台无人值守，不能选需要验证码的入口
        self.login_mode = login_mode or background_login_mode()

    def _create_session(self, prefer_saved: bool = True) -> requests.Session:
        """创建并认证一个新的 Session

        优先复用已保存的登录会话（省掉一次登录、也避开验证码）；
        失效时用凭据重新登录。
        """
        return create_authenticated_session(
            self.username,
            self.password,
            mode=self.login_mode,
            prefer_saved=prefer_saved,
        )

    def _relogin_session(self) -> requests.Session:
        """丢弃落盘会话，强制用凭据重新登录（用于 401 自愈）"""
        return force_relogin(self.username, self.password, self.login_mode)

    def fetch_latest_grades(self) -> dict[str, Any]:
        """
        获取最新成绩，返回按课程号 (kth) 索引的字典

        Returns:
            dict: { kth: course_dict, ... }
        """
        result = self._fetch_json_with_retry()
        grades_dict = {}
        for course in result.get("data", []):
            kth = course.get("kth")
            if kth:
                grades_dict[kth] = course
        return grades_dict

    def fetch_grade_json(self) -> dict[str, Any]:
        """获取原始成绩 JSON（用于 API 透传）"""
        return self._fetch_json_with_retry()

    def _fetch_json_with_retry(self) -> dict[str, Any]:
        """拉取成绩；遇到服务端会话失效时强制重登并重试一次

        背景（2026-11-07 真机故障）：落盘会话的 JWT 还有效，但服务端
        session 已被清理，查询一路 401.1006。监控循环里异常只被记录，
        于是通知静默失效。这里做一次自愈重登，避免整轮白跑。
        """
        session = self._create_session()
        try:
            try:
                result = fetch_all_grades(session)
            except Exception as e:
                if not _is_auth_failure(e):
                    raise
                logger.warning(f"成绩查询遇认证失效，强制重登后重试一次: {e}")
                session.close()
                session = self._relogin_session()
                result = fetch_all_grades(session)
        finally:
            try:
                session.close()
            except Exception:
                pass

        if result.get("errorCode") != "success":
            raise Exception(f"成绩 API 返回错误: {result.get('errorMessage')}")
        return result
