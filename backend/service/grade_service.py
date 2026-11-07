# backend/service/grade_service.py
"""
成绩查询服务

使用已认证的 Session 请求教务系统成绩 API，返回结构化数据。
"""
import requests
from typing import Any

from backend.auth.login import create_authenticated_session, saved_login_mode
from backend.utils.logger import get_logger

logger = get_logger(__name__)


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
        # 未显式指定时沿用上次成功登录的方式（避免 CAS 用户被拽回 v.ruc）
        self.login_mode = login_mode or saved_login_mode()

    def _create_session(self) -> requests.Session:
        """创建并认证一个新的 Session

        优先复用已保存的登录会话（省掉一次登录、也避开验证码）；
        失效时用凭据重新登录。
        """
        return create_authenticated_session(
            self.username,
            self.password,
            mode=self.login_mode,
            prefer_saved=True,
        )

    def fetch_latest_grades(self) -> dict[str, Any]:
        """
        获取最新成绩，返回按课程号 (kth) 索引的字典

        Returns:
            dict: { kth: course_dict, ... }
        """
        session = self._create_session()
        try:
            result = fetch_all_grades(session)
            if result.get("errorCode") != "success":
                raise Exception(
                    f"成绩 API 返回错误: {result.get('errorMessage')}"
                )
            course_list = result.get("data", [])
            grades_dict = {}
            for course in course_list:
                kth = course.get("kth")
                if kth:
                    grades_dict[kth] = course
            return grades_dict
        finally:
            session.close()

    def fetch_grade_json(self) -> dict[str, Any]:
        """获取原始成绩 JSON（用于 API 透传）"""
        session = self._create_session()
        try:
            result = fetch_all_grades(session)
            if result.get("errorCode") != "success":
                raise Exception(
                    f"成绩 API 返回错误: {result.get('errorMessage')}"
                )
            return result
        finally:
            session.close()
