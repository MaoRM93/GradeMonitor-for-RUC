# backend/auth/cas_login.py
"""CAS 统一身份认证登录（登录方式 3：cas.ruc.edu.cn）

2026-11-07 实测结论（校园网内 / 移动热点外网均验证通过）：
  · 入口链：GET jw `/secService/oauthlogin`（不带 code）
        → 302 `cas/oauth2.0/authorize`
        → 302 `cas/cas/login?service=...callbackAuthorize`
  · **强制验证码**：`/cas/captcha.jpg` 是 60x20 的 4 位数字 jpeg，无法自动识别，
    必须由用户肉眼识读后输入。验证码一次性，每次重登都要重新取。
  · **不需要对密码做 RSA 加密**：表单里虽有 `encrypted=true` 和前端公钥，
    但明文 `password` 直接提交即可通过（实测 302 拿 ticket）。
  · 表单字段：`username` / `password` / `authcode` / `rememberMe` /
    `execution`(隐藏) / `_eventId=submit` / `loginType=1`。
  · `rememberMe=true` 时下发 `CASTGC`（7 天）；不带则只有会话级 cookie。
  · 拿票成功后依次 302：`callbackAuthorize` → jw `oauthlogin2` → `Njw2017/index.html`，
    落地后 jw 侧种下 SESSION / token / authcode。
  · **免验证码静默续期**：只要 CASTGC 还在，直接 GET `oauth2.0/authorize`
    就会自动发新 ticket（不再问验证码）——所以验证码每 7 天才需要输一次。
"""
import time
from typing import Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

from backend.utils.logger import get_logger

logger = get_logger(__name__)

CAS_BASE = "https://cas.ruc.edu.cn"
CAS_LOGIN_PAGE = CAS_BASE + "/cas/login"
CAS_CAPTCHA = CAS_BASE + "/cas/captcha.jpg"
JW_BASE = "https://jw.ruc.edu.cn"
OAUTHLOGIN_ENTRY = JW_BASE + "/secService/oauthlogin"

CAS_HOST = "cas.ruc.edu.cn"

_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def new_session() -> requests.Session:
    """创建 CAS 登录用的 Session"""
    session = requests.Session()
    session.trust_env = False
    session.headers.update({
        "User-Agent": _USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
    })
    return session


def _cas_login_url(session: requests.Session) -> str:
    """走一遍入口链，拿到带 service 参数的 CAS 登录页地址"""
    resp = session.get(OAUTHLOGIN_ENTRY, timeout=20)
    url = resp.url or ""
    if "/cas/login" in url:
        return url
    # 未自动跳到登录页时，手动补一跳
    resp2 = session.get(
        CAS_BASE + "/cas/oauth2.0/authorize", timeout=20, allow_redirects=True
    )
    return resp2.url or CAS_LOGIN_PAGE


def captcha_required() -> bool:
    """CAS 是否强制验证码 —— 实测始终为 True，保留函数以便将来兼容"""
    return True


def fetch_captcha(session: requests.Session) -> tuple[bytes, str]:
    """下载验证码图片并返回 (图片字节, CAS 登录页 URL)

    必须**先取登录页再取验证码**：每次 GET 登录页都会刷新 execution，
    旧验证码随之失效。
    """
    login_url = _cas_login_url(session)
    resp = session.get(CAS_CAPTCHA, timeout=20, headers={"Referer": login_url})
    if resp.status_code != 200 or not resp.content:
        raise RuntimeError(f"获取 CAS 验证码失败: HTTP {resp.status_code}")
    return resp.content, login_url


def _hidden_fields(html: str, form_id: str = "fm1") -> dict:
    """提取表单里的隐藏字段（execution 等）"""
    soup = BeautifulSoup(html, "html.parser")
    form = soup.find("form", {"id": form_id}) or soup.find("form")
    if not form:
        return {}
    fields = {}
    for inp in form.find_all("input"):
        name = inp.get("name")
        if not name:
            continue
        if (inp.get("type") or "").lower() == "hidden":
            fields[name] = inp.get("value") or ""
    return fields


def _apply_jw_cookies(session: requests.Session) -> list[str]:
    return list(session.cookies.get_dict(domain="jw.ruc.edu.cn").keys())


def login(
    session: requests.Session,
    username: str,
    password: str,
    captcha: str,
    remember_me: bool = True,
) -> None:
    """执行 CAS 统一认证登录

    Args:
        session: CAS 登录用的 Session（同一实例后续会被复用）
        username: 学号
        password: 密码
        captcha: 用户识读的 4 位验证码
        remember_me: 是否记住登录（决定 CASTGC 是 7 天还是会话级）

    Raises:
        LoginError: 分类后的失败
    """
    from backend.auth.login import (
        KIND_CAPTCHA_INVALID,
        KIND_CAPTCHA_REQUIRED,
        KIND_CREDENTIALS,
        KIND_MAINTENANCE,
        KIND_NETWORK,
        KIND_SSO_FAILED,
        LoginError,
    )

    if not captcha:
        raise LoginError(KIND_CAPTCHA_REQUIRED, "CAS 登录需要验证码")

    try:
        login_url = _cas_login_url(session)
    except requests.exceptions.RequestException as e:
        raise LoginError(KIND_NETWORK, f"无法访问 CAS 登录入口: {e}") from e

    # 取登录页（刷新 execution）—— 注意顺序：页面 → 验证码 → POST
    try:
        page = session.get(login_url, timeout=20)
    except requests.exceptions.RequestException as e:
        raise LoginError(KIND_NETWORK, f"无法打开 CAS 登录页: {e}") from e

    hidden = _hidden_fields(page.text)
    execution = hidden.get("execution", "")
    if not execution:
        raise LoginError(
            KIND_MAINTENANCE,
            f"CAS 登录页未找到 execution 字段 (HTTP {page.status_code})",
        )

    form = {
        "username": username,
        "password": password,
        "authcode": captcha,
        "rememberMe": "true" if remember_me else "false",
        "execution": execution,
        "_eventId": "submit",
        "loginType": "1",
        "submit": "登 录",
    }

    try:
        resp = session.post(
            login_url,
            data=form,
            timeout=30,
            allow_redirects=False,
            headers={"Referer": login_url},
        )
    except requests.exceptions.RequestException as e:
        raise LoginError(KIND_NETWORK, f"CAS 登录请求失败: {e}") from e

    # ---- 失败：CAS 用 200 + 页面错误文案 表达失败 ----
    if resp.status_code != 302:
        text = resp.text or ""
        if "验证码" in text and ("无效" in text or "错误" in text):
            raise LoginError(KIND_CAPTCHA_INVALID, "CAS 验证码无效")
        if "密码错误" in text or "用户名或密码" in text:
            raise LoginError(KIND_CREDENTIALS, "CAS 账号或密码错误")
        if "必须录入用户名" in text:
            raise LoginError(KIND_CREDENTIALS, "CAS 未录入用户名")
        if "维护" in text or resp.status_code >= 500:
            raise LoginError(
                KIND_MAINTENANCE, f"CAS 登录页异常 (HTTP {resp.status_code})"
            )
        raise LoginError(
            KIND_MAINTENANCE,
            f"CAS 登录未跳转 (HTTP {resp.status_code}): {text[:200]}",
        )

    ticket_url = resp.headers.get("Location") or ""
    if "ticket=" not in ticket_url:
        raise LoginError(KIND_SSO_FAILED, f"CAS 未下发 ticket: {ticket_url}")

    logger.info("CAS 已下发 ticket，开始换取教务系统会话")

    # ---- 跟随跳转链：callbackAuthorize → oauthlogin2 → index.html ----
    try:
        final = session.get(ticket_url, timeout=30, allow_redirects=True)
    except requests.exceptions.RequestException as e:
        raise LoginError(KIND_NETWORK, f"CAS ticket 换取会话失败: {e}") from e

    cookies = _apply_jw_cookies(session)
    missing = [n for n in ("SESSION", "token", "authcode") if n not in cookies]
    if not missing:
        logger.info(f"CAS 登录成功，jw cookies: {cookies}")
        return

    # 有些情况下跳转链在 callbackAuthorize 处停止，需要再走一跳
    if "callbackAuthorize" in (final.url or ""):
        try:
            session.get(OAUTHLOGIN_ENTRY, timeout=30, allow_redirects=True)
        except requests.exceptions.RequestException:
            pass
        cookies = _apply_jw_cookies(session)
        missing = [n for n in ("SESSION", "token", "authcode") if n not in cookies]
        if not missing:
            logger.info(f"CAS 登录成功（补跳一次），jw cookies: {cookies}")
            return

    raise LoginError(
        KIND_SSO_FAILED,
        f"CAS 登录后教务系统未建立完整会话（缺少 {missing}，已有 {cookies}）",
    )


# ---------------------------------------------------------------- 静默续期

def has_castgc(session: requests.Session) -> bool:
    """会话里是否还有 CASTGC（决定能否免验证码续期）"""
    return bool(session.cookies.get("CASTGC", domain=CAS_HOST))


def silent_renew(session: requests.Session) -> bool:
    """用 CASTGC 静默换新 jw 会话（不需要验证码）

    原理：CASTGC 有效时，GET `cas/oauth2.0/authorize` 会被 CAS 直接
    302 回 `callbackAuthorize?ticket=ST-...`，自动发新票。

    Returns:
        True 表示续期成功（jw cookies 齐全）
    """
    from backend.auth.login import KIND_SSO_FAILED, LoginError

    if not has_castgc(session):
        logger.info("没有 CASTGC，无法静默续期")
        return False

    try:
        resp = session.get(OAUTHLOGIN_ENTRY, timeout=25, allow_redirects=True)
    except requests.exceptions.RequestException as e:
        logger.warning(f"静默续期请求失败: {e}")
        return False

    cookies = _apply_jw_cookies(session)
    missing = [n for n in ("SESSION", "token", "authcode") if n not in cookies]
    if not missing:
        logger.info(f"CAS 静默续期成功，jw cookies: {cookies}")
        return True

    # 再补一跳 oauthlogin2（部分情况下链路停在中途）
    try:
        session.get(
            JW_BASE + "/secService/oauthlogin2", timeout=25, allow_redirects=True
        )
    except requests.exceptions.RequestException:
        pass
    cookies = _apply_jw_cookies(session)
    missing = [n for n in ("SESSION", "token", "authcode") if n not in cookies]
    if not missing:
        logger.info(f"CAS 静默续期成功（补跳），jw cookies: {cookies}")
        return True

    logger.info(f"静默续期未成功（缺少 {missing}）")
    return False


def castgc_expiry_hint(session: requests.Session) -> Optional[float]:
    """CASTGC 的过期时间戳（无则返回 None）

    CAS 的 CASTGC 值是加密串，无法本地解析；这里只用于判断"是否存在"。
    保留接口给上层做 UI 提示用。
    """
    if not has_castgc(session):
        return None
    return time.time()
