# backend/auth/login.py
"""
RUC 统一认证（OAuth2）登录流程
"""
import requests
from bs4 import BeautifulSoup
from backend.auth.oauth import AUTH_LOGIN_URL, LOGIN_URL, AUTHORIZE_URL
from backend.utils.logger import get_logger

logger = get_logger(__name__)


# ---------- 登录失败分类 ----------
#
# 认证链路上有三类完全不同的失败，处理方式也不同：
#   · CREDENTIALS  —— 统一认证明确拒绝（密码错了）
#   · MAINTENANCE  —— 认证通过了但教务系统没给会话（维护/服务端异常）
#   · NETWORK      —— 连不上任何一个服务器
#
# 以前三类都抛同一个 Exception，前端只能一律显示「账号或密码错误」，
# 维护期间会误导用户去反复改密码。现在用 LoginError 携带分类。

KIND_CREDENTIALS = "credentials"
KIND_MAINTENANCE = "maintenance"
KIND_NETWORK = "network"

# 三类失败给用户看的文案（唯一来源；前端只是兜底复用）
USER_MESSAGES = {
    KIND_CREDENTIALS: "您输入的账号或密码错误，请检查后重试",
    KIND_MAINTENANCE: "教务系统正在维护中，请稍候",
    KIND_NETWORK: "无法连接到服务器，请检查您的网络连接",
}

# 判定「教务系统维护中」的页面特征词
_MAINTENANCE_HINTS = ("维护", "暂停使用", "maintain", "upgrading")


def _looks_like_maintenance(text: str) -> bool:
    """页面内容是否像教务系统的维护公告页"""
    if not text:
        return False
    lowered = text.lower()
    return any(hint.lower() in lowered for hint in _MAINTENANCE_HINTS)


class LoginError(Exception):
    """带分类的登录失败异常

    Attributes:
        kind: KIND_CREDENTIALS / KIND_MAINTENANCE / KIND_NETWORK
        user_message: 可直接展示给用户的中文文案
    """

    def __init__(self, kind: str, message: str = "", user_message: str = ""):
        self.kind = kind
        self.user_message = user_message or USER_MESSAGES.get(kind, "")
        super().__init__(message or self.user_message)


def get_csrf_token(session: requests.Session) -> str:
    """从认证页面提取 CSRF Token"""
    resp = session.get(AUTH_LOGIN_URL)
    soup = BeautifulSoup(resp.text, "html.parser")
    token = soup.find("input", {"id": "csrftoken"})
    if not token:
        # 拿不到登录页结构：要么服务器在维护，要么接口改版
        raise LoginError(
            KIND_MAINTENANCE,
            "csrftoken not found in the authentication page.",
        )
    return token["value"]


def login_and_bind_jw(session: requests.Session, username: str, password: str):
    """
    完整认证闭环（无需验证码）

    Args:
        session: requests.Session 实例
        username: 学号
        password: 密码

    Returns:
        requests.Response: 教务系统回调的最终响应

    Raises:
        LoginError: 带分类的登录失败（凭据错误 / 维护中 / 网络不通）
    """
    try:
        return _login_and_bind_jw(session, username, password)
    except LoginError:
        raise
    except requests.exceptions.RequestException as e:
        # 任何网络层异常（DNS、连接、超时、TLS）都归为「连不上服务器」
        logger.error(f"连接教务系统失败: {e}")
        raise LoginError(KIND_NETWORK, f"request failed: {e}") from e


def _login_and_bind_jw(
    session: requests.Session, username: str, password: str
) -> requests.Response:
    csrf = get_csrf_token(session)
    logger.info(f"CSRF Token: {csrf[:10]}...")

    # 验证码字段置空（服务端可能忽略）
    data = {
        "username": f"ruc:{username}",
        "password": password,
        "code": "",
        "remember_me": "false",
        "redirect_uri": AUTHORIZE_URL,
        "token": csrf,
        "captcha_id": "",
        "twofactor_password": "",
        "twofactor_recovery": "",
    }

    resp = session.post(LOGIN_URL, json=data, allow_redirects=False)

    if resp.status_code != 302:
        logger.error(f"Unexpected status code: {resp.status_code}")
        logger.error(f"Server response body: {resp.text[:500]}")

        # 5xx 或页面里出现维护字样 → 服务端异常/维护
        if resp.status_code >= 500 or _looks_like_maintenance(resp.text):
            raise LoginError(
                KIND_MAINTENANCE,
                f"login service unavailable (HTTP {resp.status_code})",
            )

        # 其余 4xx 视为凭据被拒（RUC 返回 400 verification failed）
        try:
            soup = BeautifulSoup(resp.text, "html.parser")
            error_msg = soup.find(class_="error-msg").text.strip()
        except Exception:
            error_msg = "Please check the logs for response body."
        raise LoginError(
            KIND_CREDENTIALS,
            f"Login authentication failed (HTTP {resp.status_code}). "
            f"Reason: {error_msg}",
        )

    oauth_authorize_url = resp.headers.get("Location")
    if oauth_authorize_url and oauth_authorize_url.startswith("/"):
        oauth_authorize_url = f"https://v.ruc.edu.cn{oauth_authorize_url}"

    logger.info(f"Authentication successful. Redirecting to OAuth2: {oauth_authorize_url}")

    resp_oauth = session.get(oauth_authorize_url, allow_redirects=False)
    if resp_oauth.status_code != 302:
        # 凭据已经通过，这一步失败属于教务系统侧异常
        raise LoginError(
            KIND_MAINTENANCE,
            f"OAuth2 authorization failed (HTTP {resp_oauth.status_code})",
        )

    jw_callback_url = resp_oauth.headers.get("Location")
    if jw_callback_url and jw_callback_url.startswith("/"):
        jw_callback_url = f"https://jw.ruc.edu.cn{jw_callback_url}"

    logger.info(f"OAuth2 Code obtained. Establishing Session: {jw_callback_url.split('?')[0]}...")

    final_resp = session.get(jw_callback_url, allow_redirects=True)

    jw_cookies = session.cookies.get_dict(domain="jw.ruc.edu.cn")
    if jw_cookies:
        logger.info(f"Session successfully established for jw.ruc.edu.cn (cookies: {list(jw_cookies.keys())})")
        return final_resp

    # 凭据已通过但教务系统没发会话 cookie——典型就是维护窗口
    if _looks_like_maintenance(final_resp.text):
        logger.warning("教务系统返回维护提示页，本次登录无法建立会话")
    raise LoginError(
        KIND_MAINTENANCE,
        "Process completed, but no valid Cookie found for jw.ruc.edu.cn.",
    )
