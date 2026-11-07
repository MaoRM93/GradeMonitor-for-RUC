# backend/auth/login.py
"""
RUC 统一认证（OAuth2）登录流程

校园网内链路（2026-11 现状，已实测可用）：
    1. GET  https://v.ruc.edu.cn/auth/login       → 页面里取 csrftoken
    2. POST https://v.ruc.edu.cn/auth/login       → 302 到 /oauth2/authorize
    3. GET  /oauth2/authorize                     → 302 到 jw.ruc.edu.cn/secService/oauthlogin?code=...
    4. GET  jw 回调                                → 种下 SESSION / token / authcode

校外访问时第 1 步会被 302 到 wvpn.ruc.edu.cn（WebVPN 网关）或
cas.ruc.edu.cn（统一身份认证），那种页面里**没有 csrftoken**。
以前这种「不在校园网」会被一律报成「教务系统正在维护中」，误导用户。
"""
import requests
from bs4 import BeautifulSoup
from backend.auth.oauth import AUTH_LOGIN_URL, LOGIN_URL, AUTHORIZE_URL
from backend.utils.logger import get_logger

logger = get_logger(__name__)


# ---------- 登录失败分类 ----------
#
# 认证链路上有几类完全不同的失败，处理方式也不同：
#   · CREDENTIALS     —— 统一认证明确拒绝（密码错了）
#   · MAINTENANCE     —— 认证通过了但教务系统没给会话（真的在维护/服务端异常）
#   · NETWORK         —— 连不上任何一个服务器
#   · CAMPUS_NETWORK  —— 请求被重定向到 WebVPN / CAS，说明当前不在校园网内
#   · SSO_FAILED      —— OAuth 走完了但教务系统拒绝建会话（code 无效/过期）
#
# 关键教训：以前「取不到 csrftoken」直接归为 MAINTENANCE，校外用户会以为
# 学校在维护，反复重试甚至改密码。现在先判断是不是被网关劫走了。

KIND_CREDENTIALS = "credentials"
KIND_MAINTENANCE = "maintenance"
KIND_NETWORK = "network"
KIND_CAMPUS_NETWORK = "campus_network"
KIND_SSO_FAILED = "sso_failed"
# 验证码相关（CAS 统一认证强制验证码；教务系统直连通常不需要，风控时才会要）
KIND_CAPTCHA_REQUIRED = "captcha_required"
KIND_CAPTCHA_INVALID = "captcha_invalid"

# 各类失败给用户看的文案（唯一来源；前端只是兜底复用）
USER_MESSAGES = {
    KIND_CREDENTIALS: "您输入的账号或密码错误，请检查后重试",
    KIND_MAINTENANCE: "教务系统正在维护中，请稍候",
    KIND_NETWORK: "无法连接到服务器，请检查您的网络连接",
    KIND_CAMPUS_NETWORK: "当前不在校园网内，请连接校园网后重试",
    KIND_SSO_FAILED: "登录凭证已失效，请重新登录",
    KIND_CAPTCHA_REQUIRED: "本次登录需要验证码，请填写验证码后重试",
    KIND_CAPTCHA_INVALID: "验证码不正确，请重新输入",
}

# 判定「教务系统维护中」的页面特征词
_MAINTENANCE_HINTS = ("维护", "暂停使用", "maintain", "upgrading")

# 校外访问时会出现的网关特征——命中说明请求被转走了，不是维护
_OFF_CAMPUS_HOSTS = ("wvpn.ruc.edu.cn", "cas.ruc.edu.cn", "/account/login")

# 教务系统拒绝建立会话时的页面特征
_SSO_FAILURE_HINTS = ("单点登录获取用户信息失败", "获取用户信息失败")

# 建立会话成功必须同时具备的 cookie
# 注意：只拿到 SESSION 是不够的——code 无效时 jw 也会种 SESSION，
# 但不会给 token/authcode，后续成绩接口全部 401。
_REQUIRED_JW_COOKIES = ("SESSION", "token", "authcode")


def _looks_like_maintenance(text: str) -> bool:
    """页面内容是否像教务系统的维护公告页"""
    if not text:
        return False
    lowered = text.lower()
    return any(hint.lower() in lowered for hint in _MAINTENANCE_HINTS)


def _looks_like_sso_failure(text: str) -> bool:
    """回调页是否明确报「单点登录获取用户信息失败」"""
    if not text:
        return False
    return any(hint in text for hint in _SSO_FAILURE_HINTS)


def _off_campus_gateway(resp: requests.Response) -> str:
    """请求是否被重定向到校外网关

    Returns:
        命中的网关标识（域名或路径）；没命中返回空串
    """
    urls = [resp.url or ""]
    for hop in resp.history:
        urls.append(hop.headers.get("Location") or "")
    for url in urls:
        lowered = url.lower()
        for host in _OFF_CAMPUS_HOSTS:
            if host in lowered:
                return host
    return ""


class LoginError(Exception):
    """带分类的登录失败异常

    Attributes:
        kind: KIND_CREDENTIALS / KIND_MAINTENANCE / KIND_NETWORK
              / KIND_CAMPUS_NETWORK / KIND_SSO_FAILED
        user_message: 可直接展示给用户的中文文案
    """

    def __init__(self, kind: str, message: str = "", user_message: str = ""):
        self.kind = kind
        self.user_message = user_message or USER_MESSAGES.get(kind, "")
        super().__init__(message or self.user_message)


def get_csrf_token(session: requests.Session) -> str:
    """从认证页面提取 CSRF Token

    Raises:
        LoginError: 被转到校外网关（CAMPUS_NETWORK）或页面确实异常（MAINTENANCE）
    """
    resp = session.get(AUTH_LOGIN_URL)

    # 先判断是不是被 WebVPN / CAS 劫走了——这是「不在校园网」，不是「维护」
    gateway = _off_campus_gateway(resp)
    if gateway:
        logger.warning(f"登录页被重定向到 {gateway}，当前不在校园网内")
        raise LoginError(
            KIND_CAMPUS_NETWORK,
            f"auth login page redirected to {gateway} (off campus)",
        )

    soup = BeautifulSoup(resp.text, "html.parser")
    token = soup.find("input", {"id": "csrftoken"})
    if token:
        return token["value"]

    # 页面里没有 csrftoken、也没有被重定向：才可能是真的维护或页面改版
    if _looks_like_maintenance(resp.text):
        raise LoginError(
            KIND_MAINTENANCE,
            "authentication page shows maintenance notice.",
        )
    logger.error(f"登录页结构异常（无 csrftoken），长度 {len(resp.text)}，最终 URL {resp.url}")
    raise LoginError(
        KIND_MAINTENANCE,
        "csrftoken not found in the authentication page.",
    )


def login_and_bind_jw(session: requests.Session, username: str, password: str):
    """
    完整认证闭环（校园网内，无需验证码）

    Args:
        session: requests.Session 实例
        username: 学号
        password: 密码

    Returns:
        requests.Response: 教务系统回调的最终响应

    Raises:
        LoginError: 带分类的登录失败
    """
    try:
        return _login_and_bind_jw(session, username, password)
    except LoginError:
        raise
    except requests.exceptions.RequestException as e:
        # 任何网络层异常（DNS、连接、超时、TLS）都归为「连不上服务器」
        logger.error(f"连接教务系统失败: {e}")
        raise LoginError(KIND_NETWORK, f"request failed: {e}") from e


# ---------------------------------------------------------------- 多入口分发
#
# 三种登录入口（2026-11 用户实测定义）：
#   MODE_JW   "jw"   —— 教务系统直连，**默认**。通常不需要验证码，一步 POST 拿会话。
#   MODE_CAS  "cas"  —— CAS 统一身份认证。强制验证码，但 CASTGC 可静默续期 7 天。
#   MODE_VRUC "vruc" —— 传统 v.ruc OAuth。官方即将废弃，优先级最低。
#
# 三者最终都会得到同一套 jw cookie（SESSION/token/authcode），
# 因此下游成绩/排名/监控逻辑完全不需要区分登录方式。

MODE_JW = "jw"
MODE_CAS = "cas"
MODE_VRUC = "vruc"
DEFAULT_MODE = MODE_JW
ALL_MODES = (MODE_JW, MODE_CAS, MODE_VRUC)

# 哪些入口需要验证码（前端据此决定是否显示验证码输入框）
MODES_NEED_CAPTCHA = (MODE_CAS,)


def mode_needs_captcha(mode: str) -> bool:
    """该登录入口是否**固定**需要验证码

    注意：教务系统直连在触发风控时也可能要验证码，那种情况由
    `login_by_mode` 抛出 KIND_CAPTCHA_REQUIRED 让前端动态补输入框。
    """
    return mode in MODES_NEED_CAPTCHA


def normalize_mode(mode: str) -> str:
    """规范化登录方式字符串，非法值回落到默认入口"""
    value = (mode or "").strip().lower()
    if value in ALL_MODES:
        return value
    return DEFAULT_MODE


def create_authenticated_session(
    username: str,
    password: str,
    mode: str = DEFAULT_MODE,
    prefer_saved: bool = True,
):
    """为后台任务（成绩/排名/监控）创建一个已认证的 Session

    优先复用落盘会话（省掉一次登录、也避开验证码）；失效时用给定
    凭据重新登录。CAS 入口若需要验证码而用户不在场，会抛出
    KIND_CAPTCHA_REQUIRED —— 监控循环会捕获并跳过本轮。

    Args:
        username: 学号
        password: 密码
        mode: 登录方式（通常取 settings 里保存的值）
        prefer_saved: 是否先尝试恢复已保存会话

    Returns:
        已认证的 requests.Session
    """
    from backend.auth import cas_login, jw_login, session_store

    actual = normalize_mode(mode)
    session = cas_login.new_session() if actual == MODE_CAS else jw_login.new_session()

    if prefer_saved:
        payload = session_store.load() or {}
        saved_mode = payload.get("login_mode") or ""
        # 只要落盘会话可用就复用，不因"上次登录入口"与当前设置不同而放弃：
        # 一个有效会话对任何入口都有效，而复用能避免 CAS 再要一次验证码。
        if saved_mode and try_restore_session(session):
            return session

    try:
        login_by_mode(session, username, password, mode=actual)
    except Exception:
        try:
            session.close()
        except Exception:
            pass
        raise

    # 登录后立即探活：登录成功但服务端会话异常（风控/多端顶号）时尽早暴露，
    # 不要等到监控循环里 401 才失败。
    state = jw_login.probe_session(session)
    if state == jw_login.PROBE_EXPIRED:
        logger.warning("刚登录的会话探活即判定失效，本次查询可能失败")
    return session


def saved_login_mode() -> str:
    """读取上次成功登录使用的方式（用于后台任务复用）"""
    from backend.auth import session_store

    payload = session_store.load() or {}
    return normalize_mode(payload.get("login_mode") or "")


def background_login_mode() -> str:
    """后台任务（成绩/排名/监控）应使用的登录入口

    后台无人值守，**不能选需要验证码的入口**——CAS 一到期就会抛
    KIND_CAPTCHA_REQUIRED 让整轮查询失败。教务系统直连（jw）与 CAS 用的是
    同一套微人大账号，且通常不需要验证码，因此后台优先用它：
      · 上次登录方式不需要验证码 → 沿用它
      · 上次是 CAS 等需要验证码的入口 → 回落到默认入口（jw）
    """
    saved = saved_login_mode()
    if saved and not mode_needs_captcha(saved):
        return saved
    return DEFAULT_MODE


def force_relogin(
    username: str,
    password: str,
    preferred_mode: str = "",
) -> requests.Session:
    """丢弃落盘会话，用凭据强制重新登录（后台 401 自愈用）

    与 `create_authenticated_session` 的区别：不复用落盘会话，且入口若需要
    验证码会自动回落到默认入口，保证无人值守场景不会卡在验证码上。

    Args:
        username: 学号
        password: 密码
        preferred_mode: 首选入口（空则用 background_login_mode()）

    Returns:
        已认证的 requests.Session
    """
    from backend.auth import cas_login, jw_login, session_store

    try:
        session_store.clear()
    except Exception as e:
        logger.warning(f"清除落盘会话失败（继续重登）: {e}")

    mode = normalize_mode(preferred_mode or background_login_mode())
    if mode_needs_captcha(mode):
        logger.info(f"后台重登：入口 {mode} 需要验证码，回落默认入口 {DEFAULT_MODE}")
        mode = DEFAULT_MODE

    session = cas_login.new_session() if mode == MODE_CAS else jw_login.new_session()
    try:
        login_by_mode(session, username, password, mode=mode)
    except Exception:
        try:
            session.close()
        except Exception:
            pass
        raise
    return session


def login_by_mode(
    session: requests.Session,
    username: str,
    password: str,
    mode: str = DEFAULT_MODE,
    captcha: str = "",
) -> str:
    """按登录入口分发认证，并把结果会话持久化

    Args:
        session: 待认证的 Session
        username: 学号
        password: 密码
        mode: "jw" / "cas" / "vruc"
        captcha: 验证码（仅 cas 或触发风控的 jw 需要）

    Returns:
        实际使用的登录方式

    Raises:
        LoginError: 带分类的登录失败
    """
    from backend.auth import cas_login, jw_login, session_store

    actual = normalize_mode(mode)
    logger.info(f"开始登录（方式={actual}, 用户={username}）")

    try:
        if actual == MODE_JW:
            jw_login.login(session, username, password, captcha)
        elif actual == MODE_CAS:
            cas_login.login(session, username, password, captcha)
        else:
            login_and_bind_jw(session, username, password)
    except LoginError:
        raise
    except requests.exceptions.RequestException as e:
        logger.error(f"连接认证服务器失败: {e}")
        raise LoginError(KIND_NETWORK, f"request failed: {e}") from e

    # 落盘会话，供监控循环与下次启动免登录复用
    try:
        session_store.save(session_store.snapshot(session), login_mode=actual)
    except Exception as e:
        logger.warning(f"会话持久化失败（不影响本次登录）: {e}")

    return actual


def try_restore_session(session: requests.Session) -> bool:
    """尝试用已保存的 cookie 恢复会话（免登录）

    流程：
      1. 读落盘的 cookie 灌进 session
      2. jw token 本地未过期 → 再向服务端**探活**确认（关键，见下）
      3. 服务端判定失效（401.1006 sid 不匹配）→ 用 CASTGC 静默续期
      4. 都不行 → 返回 False，由用户重新登录

    为什么本地 exp 校验不够（2026-11-07 真机故障）：JWT 有效期 12 小时，
    但服务端会话记录可能更早被清理。此时 `token_valid()` 仍返回 True，
    后台任务带着"看起来有效"的 cookie 一路 401.1006，成绩查询在 diff 前
    就抛异常，通知因此静默失效。所以必须打一次真实请求探活。

    Returns:
        True 表示会话可用
    """
    from backend.auth import cas_login, jw_login, session_store

    payload = session_store.load()
    if not payload:
        return False

    jw_count = session_store.apply_to_session(session, "jw.ruc.edu.cn")
    session_store.apply_to_session(session, "cas.ruc.edu.cn")
    if not jw_count:
        return False

    if jw_login.token_valid(session):
        # 本地 exp 通过，但必须再问一次服务端：会话可能已被提前清理
        state = jw_login.probe_session(session)
        if state == jw_login.PROBE_OK:
            logger.info("已保存的教务会话经探活确认有效，免登录恢复成功")
            return True
        if state == jw_login.PROBE_EXPIRED:
            logger.info("教务 token 本地未过期但服务端已失效，改用 CASTGC 静默续期")
        else:
            # 网络异常等无法判定：保守沿用原会话，避免网络抖动时误踢用户
            logger.warning("会话探活无法判定（网络异常），暂时沿用已保存会话")
            return True
    else:
        logger.info("教务 token 已过期，尝试用 CASTGC 静默续期")

    if cas_login.silent_renew(session):
        state = jw_login.probe_session(session)
        if state == jw_login.PROBE_EXPIRED:
            logger.info("静默续期后探活仍判定失效，需要重新登录")
            return False
        try:
            session_store.save(
                session_store.snapshot(session),
                login_mode=payload.get("login_mode", ""),
            )
        except Exception:
            pass
        return True

    logger.info("静默续期失败，需要重新登录")
    return False


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

        # 登录 POST 也可能被网关拦下（会话过期后 proxy 模式会跳登录页）
        gateway = _off_campus_gateway(resp)
        if gateway:
            raise LoginError(
                KIND_CAMPUS_NETWORK,
                f"login POST redirected to {gateway} (off campus)",
            )

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

    # 必须三个 cookie 齐全才算成功：code 无效时 jw 只种 SESSION，
    # 旧代码只判断「有没有 cookie」，会把这种失败误判为登录成功。
    missing = [name for name in _REQUIRED_JW_COOKIES if name not in jw_cookies]
    if not missing:
        logger.info(
            f"Session successfully established for jw.ruc.edu.cn "
            f"(cookies: {list(jw_cookies.keys())})"
        )
        return final_resp

    logger.error(
        f"教务系统未建立完整会话，缺少 cookie: {missing} "
        f"(已有: {list(jw_cookies.keys())})"
    )

    # 回调页明确报 SSO 失败 → code 无效/过期
    if _looks_like_sso_failure(final_resp.text):
        raise LoginError(
            KIND_SSO_FAILED,
            "jw callback page reported '单点登录获取用户信息失败' "
            f"(missing cookies: {missing})",
        )

    # 凭据已通过但教务系统没发完整会话——典型就是维护窗口
    if _looks_like_maintenance(final_resp.text):
        logger.warning("教务系统返回维护提示页，本次登录无法建立会话")
        raise LoginError(
            KIND_MAINTENANCE,
            "教务系统返回维护提示页，未能建立会话。",
        )

    raise LoginError(
        KIND_MAINTENANCE,
        "Process completed, but no valid Cookie found for jw.ruc.edu.cn. "
        f"(missing: {missing})",
    )
