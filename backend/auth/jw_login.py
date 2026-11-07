# backend/auth/jw_login.py
"""教务系统直连登录（登录方式 2：jw.ruc.edu.cn）

2026-11-07 校园网内实测结论：
  · 该入口**通常不需要验证码**：`secService/kaptcha/check/must.json`
    返回 `data: false`。只有服务端风控判定需要时才要求验证码，
    因此这里保留验证码分支（`kaptcha` 无验证码时传字面量 "testa"）。
  · 登录体里 `userCodeType` 必须是 **"ldap"**（微人大账号）。
    传 "account"（新教务账号体系）会得到
    `security.httpstatu.401.1001`「密码错误3次后账户将被锁定30分钟」。
  · 请求头是硬要求，缺一不可：
      - `app: PCWEB`            → 缺失报 security.RequestHolder.app.isNull
      - `userRoleCode: student` → 缺失报 userCurrentRole.isNull
      - `Accept: application/json` → 缺失时网关回 XML，后续接口"成功但 0 门课"
  · 成功后 `data.token` 是 JWT（12 小时），`data.authcode` 是学号；
    需要手工写进 cookie —— 浏览器的 login.js 也是这么干的。

与旧的 v.ruc OAuth 流程相比，这条链路没有 CSRF、没有 OAuth 跳转，
一步 POST 就能拿到会话，是最稳的默认入口。
"""
import base64
import json
import time
from typing import Optional

import requests

from backend.utils.logger import get_logger

logger = get_logger(__name__)

JW_BASE = "https://jw.ruc.edu.cn"
SEC_API = JW_BASE + "/secService"
LOGIN_PAGE = JW_BASE + "/Njw2017/login.html"

_KAPTCHA_HEADER = {"KAPTCHA-KEY-GENERATOR-REDIS": "securityKaptchaRedisServiceAdapter"}

# 教务网关（2026-11 起）要求的固定请求头
JW_HEADERS = {
    "app": "PCWEB",
    "X-Requested-With": "XMLHttpRequest",
    "locale": "zh_CN",
    "userRoleCode": "student",
    "Accept": "application/json",
    "Origin": JW_BASE,
    "Referer": LOGIN_PAGE,
}

_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def new_session() -> requests.Session:
    """创建带教务系统必需请求头的 Session"""
    session = requests.Session()
    session.trust_env = False
    session.headers.update({
        "User-Agent": _USER_AGENT,
        "Accept-Language": "zh-CN,zh;q=0.9",
        **_KAPTCHA_HEADER,
        **JW_HEADERS,
    })
    return session


def captcha_required(session: requests.Session) -> bool:
    """询问服务端本次登录是否需要验证码

    失败时保守返回 False（当成不需要），让登录 POST 去给出真实错误。
    """
    url = (
        SEC_API
        + "/kaptcha/check/must.json?resourceCode=resourceCode&t="
        + str(int(time.time() * 1000))
    )
    try:
        resp = session.get(url, timeout=15)
        payload = resp.json()
        need = bool(payload.get("data"))
        logger.info(f"教务系统登录是否需要验证码: {need}")
        return need
    except Exception as e:
        logger.warning(f"查询验证码要求失败（按不需要处理）: {e}")
        return False


def fetch_captcha(session: requests.Session) -> bytes:
    """下载验证码图片（4 位数字，约 60x20 的 jpeg）"""
    url = (
        SEC_API
        + "/kaptcha?t="
        + str(int(time.time() * 1000))
        + "&KAPTCHA-KEY-GENERATOR-REDIS=securityKaptchaRedisServiceAdapter"
    )
    resp = session.get(url, timeout=20)
    if resp.status_code != 200 or not resp.content:
        raise RuntimeError(f"获取验证码失败: HTTP {resp.status_code}")
    return resp.content


def _apply_tokens(session: requests.Session, data: dict, username: str) -> None:
    """把登录响应里的 token / authcode 写进 cookie

    requests 不会执行 JS，而浏览器的 login.js 正是用 JS 写这两个 cookie 的，
    所以这里必须手工补上，否则后续成绩/排名接口拿不到认证信息。
    """
    token = data.get("token") or ""
    authcode = data.get("authcode") or username
    if token:
        session.cookies.set("token", token, domain="jw.ruc.edu.cn", path="/")
    if authcode:
        session.cookies.set("authcode", str(authcode), domain="jw.ruc.edu.cn", path="/")


def login(
    session: requests.Session,
    username: str,
    password: str,
    captcha: str = "",
) -> None:
    """执行教务系统直连登录

    成功后 session 内会带上 jw 的 SESSION / token / authcode。

    Raises:
        LoginError: 分类后的失败（凭据错误 / 验证码 / 网络 / 维护）
    """
    # 延迟导入，避免与 login.py 形成循环依赖
    from backend.auth.login import (
        KIND_CAPTCHA_INVALID,
        KIND_CAPTCHA_REQUIRED,
        KIND_CREDENTIALS,
        KIND_MAINTENANCE,
        KIND_NETWORK,
        LoginError,
    )

    # 先访问登录页，让服务端种下会话 cookie（风控/验证码都绑在这个会话上）
    try:
        session.get(LOGIN_PAGE, timeout=20)
    except requests.exceptions.RequestException as e:
        raise LoginError(KIND_NETWORK, f"无法访问教务系统登录页: {e}") from e

    need = captcha_required(session)
    if need and not captcha:
        raise LoginError(KIND_CAPTCHA_REQUIRED, "教务系统本次登录需要验证码")

    body = {
        "userCode": username,
        "password": password,
        # 无验证码时前端也传字面量 "testa"，服务端会忽略
        "kaptcha": captcha or "testa",
        "userCodeType": "ldap",
    }

    try:
        resp = session.post(
            SEC_API + "/login", json=body, timeout=30, allow_redirects=False
        )
    except requests.exceptions.RequestException as e:
        raise LoginError(KIND_NETWORK, f"登录请求失败: {e}") from e

    if resp.status_code >= 500:
        raise LoginError(
            KIND_MAINTENANCE, f"教务系统登录接口异常 (HTTP {resp.status_code})"
        )

    try:
        payload = resp.json()
    except Exception:
        raise LoginError(
            KIND_MAINTENANCE,
            f"登录响应不是 JSON (HTTP {resp.status_code}): {resp.text[:200]}",
        )

    error_code = str(payload.get("errorCode") or "")
    if error_code == "success":
        data = payload.get("data") or {}
        if not isinstance(data, dict) or not data.get("token"):
            raise LoginError(
                KIND_MAINTENANCE, f"登录成功但未返回 token: {str(payload)[:200]}"
            )
        _apply_tokens(session, data, username)
        logger.info(
            f"教务系统直连登录成功 (userCodeType=ldap, cookies: "
            f"{list(session.cookies.get_dict(domain='jw.ruc.edu.cn').keys())})"
        )
        return

    # ---- 失败分类 ----
    message = str(payload.get("errorMessage") or "")
    params = payload.get("errorMessageParam") or []
    lowered = (message + " " + " ".join(map(str, params))).lower()

    if "kaptcha" in lowered or "验证码" in " ".join(map(str, params)):
        raise LoginError(KIND_CAPTCHA_INVALID, f"验证码错误: {message} {params}")

    if error_code.endswith("401.1001") or "密码" in " ".join(map(str, params)):
        raise LoginError(
            KIND_CREDENTIALS, f"账号或密码错误: {message} {params}"
        )

    if "维护" in str(params) or "maintain" in lowered:
        raise LoginError(KIND_MAINTENANCE, f"教务系统维护中: {message} {params}")

    raise LoginError(
        KIND_CREDENTIALS if error_code.startswith("security.httpstatu.401") else KIND_MAINTENANCE,
        f"登录失败 ({error_code}): {message} {params}",
    )


def token_expiry(session: requests.Session) -> Optional[float]:
    """解析 jw token(JWT) 的过期时间戳；解析失败返回 None"""
    token = session.cookies.get("token", domain="jw.ruc.edu.cn")
    if not token:
        return None
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload))
        return float(data.get("exp") or 0) or None
    except Exception:
        return None


def token_valid(session: requests.Session, skew_seconds: int = 300) -> bool:
    """jw token 是否仍在有效期内（预留 skew 秒余量）"""
    exp = token_expiry(session)
    return bool(exp and exp > time.time() + skew_seconds)
