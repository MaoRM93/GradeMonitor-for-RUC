# backend/service/developer_auth.py
"""开发者身份鉴权：用 GitHub 账号 + 令牌确认"操作者确实是作者本人"。

## 为什么不是密码

旧实现读环境变量 `GRADEMONITOR_DEVELOPER_PASSWORD`，但前端拉起后端时从未
注入过它（`frontend/lib/core/service/backend_service.dart` 只注入
`GRADEMONITOR_APP_PATH` 与 `GRADEMONITOR_API_TOKEN`），于是发行版里解锁
恒返回 503——开发者面板等于永远打不开。而且"一个固定口令"写在源码里就
等于公开（本仓库是开源的），写在环境变量里则要求用户手工 export。

改为：操作者必须持有一个**只属于作者本人**的 GitHub 令牌。令牌不在源码里、
不在仓库里，别人 clone 源码也拿不到。这就是本方案真正的安全边界。

## 三个输入框

UI 只显示三个标签（契约要求，不得增删）：

  - `LoginMngID` —— 管理者编号，必须命中内置管理者注册表（当前只有 `MaoRM93`）
  - `Account`    —— 本次登录的 GitHub 账号名，必须与 `LoginMngID` 指向同一个人
  - `Password`   —— GitHub 令牌（classic PAT 或 fine-grained PAT）

GitHub 官方**没有**"账号 + 密码换令牌"的 API（密码登录早已废弃，且需要
CSRF token 与二次验证），所以 `Password` 语义上必须是令牌。这一点在前端
输入框的 helper 文案里已注明，不额外增加可见标签。

## 校验流程

1. 三个字段非空。
2. `LoginMngID` 命中注册表 → 得到期望的 GitHub 数字 `id` 与 login。
3. `Account` 与期望 login 忽略大小写相等（仅作前置过滤，不做安全判定）。
4. 用 `Password` 调 `GET https://api.github.com/user`，返回的 **`id` 必须等于
   注册表里的数字 id**，且 `type` 必须是 `"User"`。
5. 全部通过 → 令牌与身份写入系统凭据存储（macOS 钥匙串 / Windows DPAPI），
   并把本进程标记为已解锁。

## 为什么主判定是数字 id 而不是 login

GitHub 的用户名**可以被改名，改名后旧名会被释放，任何人都能抢注**。如果判定
写成 `login == "MaoRM93"`，那么作者一旦改名，别人抢注 `MaoRM93` 后用自己账号的
令牌就能通过校验。数字 `id` 永不变、永不可被他人认领，所以它是唯一可靠的判定
依据；`login` 只用于展示与本地记录。

任何一步失败都抛同一条错误，避免用不同文案做账号探测的 oracle。

## 与旧机制的关系

- `settings.json` 的 `developer_options_enabled` **不再**参与鉴权。那个字段
  是本地明文，任何人改一下就能"解锁"，把它当门禁等于没门禁。它现在只作为
  "面板是否展开"的 UI 提示保留，鉴权一律看凭据存储里有没有有效令牌。
- `GRADEMONITOR_DEVELOPER_PASSWORD` 被本模块取代，不再读取。
"""
from dataclasses import dataclass
from typing import Optional

import requests

from backend.storage.credentials import (
    clear_secret,
    load_secret,
    save_secret,
)
from backend.utils.logger import get_logger

logger = get_logger(__name__)


@dataclass(frozen=True)
class Manager:
    """一位合法开发者。

    `user_id` 是 GitHub 的数字 id，**唯一可靠的判定依据**；`login` 仅供展示。
    """

    mng_id: str
    login: str
    user_id: int


# 内置管理者注册表。将来要加人只需在这里追加一项，无需改动任何校验逻辑。
MANAGERS: tuple[Manager, ...] = (
    Manager(mng_id="MaoRM93", login="MaoRM93", user_id=120912792),
)

# 凭据存储里的条目名（只用小写字母、数字、连字符，满足 credentials 的命名约束）
_SECRET_TOKEN = "developer-token"
_SECRET_LOGIN = "developer-login"
_SECRET_MNGID = "developer-mngid"
_SECRET_USERID = "developer-userid"

_GITHUB_USER_URL = "https://api.github.com/user"
_GITHUB_TIMEOUT = 15

# 统一的拒绝文案（前端原样红字显示）
REJECT_MESSAGE = "您登录的不是合法的开发者账户。"
NETWORK_MESSAGE = "无法连接 GitHub 验证身份，请检查网络后重试。"


class DeveloperAuthError(Exception):
    """鉴权失败。`message` 可直接展示给用户。"""

    def __init__(self, message: str, status_code: int = 401):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


# --------------------------------------------------------------- 会话状态

def _lookup(mng_id: str) -> Optional[Manager]:
    """按管理者编号查注册表（编号大小写不敏感）。"""
    key = (mng_id or "").strip()
    if not key:
        return None
    for m in MANAGERS:
        if m.mng_id.lower() == key.lower():
            return m
    return None


def _lookup_by_user_id(user_id: int) -> Optional[Manager]:
    for m in MANAGERS:
        if m.user_id == user_id:
            return m
    return None


def current_login() -> str:
    """已保存的开发者 GitHub 登录名；未登录时返回空串。"""
    return load_secret(_SECRET_LOGIN).strip()


def current_manager_id() -> str:
    """已保存的管理者编号；未登录时返回空串。"""
    return load_secret(_SECRET_MNGID).strip()


def has_token() -> bool:
    return bool(load_secret(_SECRET_TOKEN).strip())


def is_authenticated() -> bool:
    """本机是否存有一个通过校验的开发者身份。

    敏感操作前会周期性向 GitHub 复核令牌归属。仅靠可独立篡改的本地
    token/id 条目判断会允许同一系统用户伪造已登录状态。
    """
    token = developer_token()
    if not token:
        return False
    raw = load_secret(_SECRET_USERID).strip()
    if not raw:
        return False
    try:
        user_id = int(raw)
    except ValueError:
        return False
    manager = _lookup_by_user_id(user_id)
    if manager is None:
        return False
    try:
        actual_id, actual_login = _fetch_github_identity(token)
    except DeveloperAuthError:
        return False
    if actual_id != manager.user_id or actual_login.lower() != manager.login.lower():
        return False
    return True


def developer_token() -> str:
    """取出已保存的令牌（供控制台复用，避免用户重复粘贴 PAT）。"""
    return load_secret(_SECRET_TOKEN).strip()


# --------------------------------------------------------------- 校验与登录

def _fetch_github_identity(token: str) -> tuple[int, str]:
    """用令牌换取 GitHub 数字 id 与登录名。异常统一转成 DeveloperAuthError。"""
    try:
        r = requests.get(
            _GITHUB_USER_URL,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            timeout=_GITHUB_TIMEOUT,
        )
    except requests.RequestException as e:
        logger.warning(f"GitHub 身份校验请求失败: {e}")
        raise DeveloperAuthError(NETWORK_MESSAGE, status_code=502)

    if r.status_code == 401:
        # 令牌无效/已撤销：这是"不是合法账户"的一种，用统一文案
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)
    if r.status_code == 403:
        # 限流或令牌被限制
        logger.warning(f"GitHub 返回 403：{r.text[:200]}")
        raise DeveloperAuthError(NETWORK_MESSAGE, status_code=502)
    if not r.ok:
        logger.warning(f"GitHub 身份校验异常 {r.status_code}：{r.text[:200]}")
        raise DeveloperAuthError(NETWORK_MESSAGE, status_code=502)

    try:
        payload = r.json()
    except ValueError:
        raise DeveloperAuthError(NETWORK_MESSAGE, status_code=502)

    # 组织 / Bot 令牌一律拒绝：注册表里只有个人账号
    if str(payload.get("type") or "") != "User":
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)

    try:
        user_id = int(payload.get("id"))
    except (TypeError, ValueError):
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)

    login = str(payload.get("login") or "").strip()
    if not login:
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)
    return user_id, login


def verify_and_store(mng_id: str, account: str, token: str) -> dict:
    """校验身份输入；通过则持久化身份并返回会话信息。

    UI 已简化为两个输入框（Account + Password），[mng_id] 因此退化为可选：
    为空时用 [account] 去注册表里反查管理者记录。两者指向同一条记录时
    行为与旧的三输入框完全一致，保留该参数是为了不破坏已有的调用方。

    失败抛 [DeveloperAuthError]，调用方转成 HTTP 错误。
    """
    mng_id = (mng_id or "").strip()
    account = (account or "").strip()
    token = (token or "").strip()

    if not account or not token:
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)

    manager = _lookup(mng_id) if mng_id else _lookup(account)
    if manager is None:
        # 未知管理者编号：与"账号不对"共用一条文案，不做区分
        logger.info("开发者登录被拒：LoginMngID 未命中注册表")
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)

    if account.lower() != manager.login.lower():
        logger.info("开发者登录被拒：Account 与 LoginMngID 指向不同账号")
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)

    user_id, actual_login = _fetch_github_identity(token)
    if user_id != manager.user_id:
        # 关键判定：数字 id 不匹配即拒绝，与 login 是否同名无关
        logger.info(
            f"开发者登录被拒：令牌属于 id={user_id}（{actual_login}），"
            f"期望 id={manager.user_id}"
        )
        raise DeveloperAuthError(REJECT_MESSAGE, status_code=401)

    # 令牌落系统凭据存储；保存的是 GitHub 返回的规范大小写
    if not save_secret(_SECRET_TOKEN, token):
        raise DeveloperAuthError("无法安全保存登录信息，请检查系统钥匙串权限。", status_code=500)
    save_secret(_SECRET_LOGIN, actual_login)
    save_secret(_SECRET_MNGID, manager.mng_id)
    save_secret(_SECRET_USERID, str(manager.user_id))

    logger.info(f"开发者身份校验通过：{actual_login} (id={manager.user_id})")
    return {
        "success": True,
        "login": actual_login,
        "manager_id": manager.mng_id,
        "message": "开发者身份已验证",
    }


def logout() -> None:
    """清除已保存的开发者身份（令牌 + 登录名 + 编号 + id）。"""
    clear_secret(_SECRET_TOKEN)
    clear_secret(_SECRET_LOGIN)
    clear_secret(_SECRET_MNGID)
    clear_secret(_SECRET_USERID)
    logger.info("已清除开发者登录信息")


def session_payload() -> dict:
    """给前端的状态快照（不含令牌本身）。"""
    authenticated = is_authenticated()
    return {
        "unlocked": authenticated,
        "login": current_login() if authenticated else "",
        "manager_id": current_manager_id() if authenticated else "",
        "token_saved": has_token() if authenticated else False,
    }
