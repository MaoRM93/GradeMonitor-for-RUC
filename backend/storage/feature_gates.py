"""功能组开关（Feature Gates，Flag-1xxx）注册表与持久化层。

与 `backend/storage/flags.py`（开发者选项里的 1.x / 2.x 调谐开关）的区别：

  - `flags.py` 的键是开发者面板上的**按钮**，语义面向调试与预留；
  - 本模块的键是**产品功能组**，每一个都对应一段真实业务代码，
    关闭即静默下线该功能（不弹窗、不报错、不留空位）。

编号规则（Flag-1001 起，按功能域分段，段内留空位供后续增补）：

  1001–1009  仪表板
  1010–1019  成绩单
  1020–1029  方案计算
  1030–1039  通知转发
  1040–1049  引导页
  1050–1059  应用外壳与系统集成
  1060–1069  更新与远程控制
  1070–1079  数据与缓存
  1080–1089  登录与会话
  1090–1099  后端监控

设计约定：

  - **默认全部开启**。这是与 `flags.py` 最大的不同：功能组开关是"下线闸门"，
    出厂必须全开，任何一条默认关闭都会让用户看到残缺的产品。
  - 关闭 = 静默隐藏/跳过。不抛异常、不写错误日志、不提示"功能已禁用"。
  - 读：磁盘缺键时用默认值补齐，**仅在真的补了键时回写**。
  - 文件损坏 / 顶层非 dict / 值非 bool：回退默认值，绝不让坏文件把产品打挂。
  - 写：整体覆盖 + 原子写（复用 `cache.atomic_write_json`）。

远期：由 GitHub 远端下发覆盖本地状态（卸载重装后仍生效），本地值作为
无远端时的回退——接口形状已按此预留（`load_gates()` 只读本地，
`apply_remote_overrides()` 留给远端层调用）。
"""
import json
import os

from backend.storage.cache import atomic_write_json, get_data_file_path
from backend.utils.logger import get_logger

logger = get_logger(__name__)

GATES_FILE = get_data_file_path("feature_gates.json")

# ---------------------------------------------------------------------------
# 注册表：id -> (名称, 描述, 功能域)
#
# 这里是**唯一事实来源**：前端通过 GET /api/features 拿到同一份表，
# 桌面功能对照表也由它生成。改名/改编号必须三处同步（本文件、契约文档、桌面表）。
# ---------------------------------------------------------------------------
GATE_REGISTRY: dict[str, dict[str, str]] = {
    # ---------- 1001–1009 仪表板 ----------
    "Flag-1001": {
        "name": "监控状态与启停",
        "desc": "仪表板顶部的监控运行状态指示、启动/停止监控按钮，以及监控是否自动拉起。",
        "group": "仪表板",
    },
    "Flag-1002": {
        "name": "立即查询",
        "desc": "仪表板「立即查询」按钮，无视定时器立刻向教务请求一次成绩与排名。",
        "group": "仪表板",
    },
    "Flag-1003": {
        "name": "最新出分卡片",
        "desc": "展示最近一次成绩或排名变动的结构化卡片（课程名、绩点、位次变化）。",
        "group": "仪表板",
    },
    "Flag-1004": {
        "name": "统计卡片组",
        "desc": "底部五张统计卡：GPA、班级排名、专业排名、修读课程、查询次数。",
        "group": "仪表板",
    },
    # ---------- 1010–1019 成绩单 ----------
    "Flag-1010": {
        "name": "课程搜索",
        "desc": "成绩单页按课程名称实时过滤的搜索框。",
        "group": "成绩单",
    },
    "Flag-1011": {
        "name": "学期筛选",
        "desc": "按学期下拉筛选成绩，含「全部」选项。",
        "group": "成绩单",
    },
    "Flag-1012": {
        "name": "核心绩范围筛选",
        "desc": "「全部课程 / 核心绩课程」范围切换，复用核心绩白名单集合。",
        "group": "成绩单",
    },
    "Flag-1013": {
        "name": "核心绩徽标",
        "desc": "工具栏右侧的核心绩数值、课程计数与口径说明悬浮提示。",
        "group": "成绩单",
    },
    "Flag-1014": {
        "name": "学期统计卡",
        "desc": "按学期汇总的课程门数、学分与 GPA 卡片行。",
        "group": "成绩单",
    },
    "Flag-1015": {
        "name": "表格排序",
        "desc": "点击表头对八列（学期/课程名/学分/平时/期末/加权/绩点/平均绩点）排序。",
        "group": "成绩单",
    },
    "Flag-1016": {
        "name": "隐藏未知课程",
        "desc": "过滤课程名为「未知课程」的记录，列表与统计同步生效。",
        "group": "成绩单",
    },
    # ---------- 1020–1029 方案计算 ----------
    "Flag-1020": {
        "name": "方案切换",
        "desc": "811 政策 / 82 政策单选切换及其算式说明。",
        "group": "方案计算",
    },
    "Flag-1021": {
        "name": "核心绩输入卡",
        "desc": "核心绩自动计算值与双击进入的自定义编辑态，含「恢复自动」按钮。",
        "group": "方案计算",
    },
    "Flag-1022": {
        "name": "学术与综合输入",
        "desc": "学术成绩（0–4.0）与综合素质拓展（0–4.0）手工输入项。",
        "group": "方案计算",
    },
    "Flag-1023": {
        "name": "计算结果卡",
        "desc": "按所选方案算出并展示学业综合成绩结果。",
        "group": "方案计算",
    },
    "Flag-1024": {
        "name": "培养方案入口",
        "desc": "按年级打开加密培养方案 PDF 的入口；受开发者开关 1.1 影响是否放开全部年级。",
        "group": "方案计算",
    },
    # ---------- 1030–1039 通知转发 ----------
    "Flag-1030": {
        "name": "Bark 通道",
        "desc": "通过 Bark 推送到 iOS 设备，含地址配置与启用开关。",
        "group": "通知转发",
    },
    "Flag-1031": {
        "name": "MeoW 通道",
        "desc": "通过 MeoW 推送到 iOS 设备，含昵称配置与启用开关。",
        "group": "通知转发",
    },
    "Flag-1032": {
        "name": "ntfy 通道",
        "desc": "通过 ntfy 服务端与主题推送到任意订阅端，含服务器地址配置。",
        "group": "通知转发",
    },
    "Flag-1033": {
        "name": "通道测试",
        "desc": "各转发通道的「测试通道」按钮，立即发送一条测试推送。",
        "group": "通知转发",
    },
    # ---------- 1040–1049 引导页 ----------
    "Flag-1040": {
        "name": "法律声明页",
        "desc": "首次启动的免责声明与协议正文，含 10 秒倒计时与同意勾选。",
        "group": "引导页",
    },
    "Flag-1041": {
        "name": "登录方式选择",
        "desc": "引导页的登录方式选项卡（教务直连 / CAS / 统一身份认证）。",
        "group": "引导页",
    },
    "Flag-1042": {
        "name": "账号登录",
        "desc": "学号密码输入、验证码获取与提交登录的完整表单。",
        "group": "引导页",
    },
    "Flag-1043": {
        "name": "监控设置引导",
        "desc": "引导页的监控时间段、轮询间隔与监控项目配置。",
        "group": "引导页",
    },
    "Flag-1044": {
        "name": "通知模式引导",
        "desc": "引导页的详细 / 简洁通知模式选择。",
        "group": "引导页",
    },
    "Flag-1045": {
        "name": "完成页",
        "desc": "引导流程收尾的配置摘要与进入主界面。",
        "group": "引导页",
    },
    # ---------- 1050–1059 应用外壳与系统集成 ----------
    "Flag-1050": {
        "name": "自绘标题栏",
        "desc": "顶部自绘标题栏：应用名、拖拽区、最小化/最大化/关闭按钮。",
        "group": "应用外壳",
    },
    "Flag-1051": {
        "name": "侧边导航",
        "desc": "左侧导航栏及五个页面切换入口。",
        "group": "应用外壳",
    },
    "Flag-1052": {
        "name": "系统托盘",
        "desc": "菜单栏 / 任务栏托盘图标与右键菜单（开启主界面、退出程序）。",
        "group": "应用外壳",
    },
    "Flag-1053": {
        "name": "原生系统通知",
        "desc": "成绩与排名变动时弹出的系统通知，含 osascript 兜底路径。",
        "group": "应用外壳",
    },
    "Flag-1054": {
        "name": "通知点击唤起",
        "desc": "点击系统通知时把主窗口提到前台。",
        "group": "应用外壳",
    },
    "Flag-1055": {
        "name": "开机自启动",
        "desc": "随系统登录自动启动应用，受设置页开关控制。",
        "group": "应用外壳",
    },
    # ---------- 1060–1069 更新与远程控制 ----------
    "Flag-1060": {
        "name": "检查更新",
        "desc": "向 GitHub Releases 查询新版本并与本地版本比对。",
        "group": "更新与远程",
    },
    "Flag-1061": {
        "name": "应用内下载",
        "desc": "在应用内下载安装包到「下载」文件夹，含进度与原子改名。",
        "group": "更新与远程",
    },
    "Flag-1062": {
        "name": "自动安装替换",
        "desc": "下载完成后退出应用并自动替换安装的完整流程。",
        "group": "更新与远程",
    },
    "Flag-1063": {
        "name": "安装包签名校验",
        "desc": "Ed25519 + SHA-256 校验清单，无有效签名则拒绝自动安装。",
        "group": "更新与远程",
    },
    "Flag-1064": {
        "name": "114 号段广播",
        "desc": "右上角广播通知卡（仅「好」一个按钮），由 Releases 号段控制。",
        "group": "更新与远程",
    },
    "Flag-1065": {
        "name": "蓝屏开发者提醒",
        "desc": "developer-alert 通道下发的蓝色整页提醒，点「好」即关闭。",
        "group": "更新与远程",
    },
    "Flag-1066": {
        "name": "红屏停用页",
        "desc": "service-suspension 通道下发的红色整页停用，可远程终止客户端使用。",
        "group": "更新与远程",
    },
    "Flag-1067": {
        "name": "查询滥用保护",
        "desc": "60 秒滑窗内查询超阈值的客户端自动禁用，防止对教务高频请求。",
        "group": "更新与远程",
    },
    # ---------- 1070–1079 数据与缓存 ----------
    "Flag-1070": {
        "name": "成绩本地缓存",
        "desc": "把成绩落到 local_grades.json，用于增量比对与离线展示。",
        "group": "数据与缓存",
    },
    "Flag-1071": {
        "name": "排名本地缓存",
        "desc": "把专业排名与班级排名落到 local_ranks.json。",
        "group": "数据与缓存",
    },
    "Flag-1072": {
        "name": "最近变动记录",
        "desc": "把最近一次成绩/排名变动写入 recent_change.json 供仪表板读取。",
        "group": "数据与缓存",
    },
    "Flag-1073": {
        "name": "查询次数统计",
        "desc": "累计查询次数并落盘，用于统计卡展示与首次查询判定。",
        "group": "数据与缓存",
    },
    "Flag-1074": {
        "name": "WebSocket 实时推送",
        "desc": "后端事件经 /ws/events 推到前端，触发界面自动刷新与通知。",
        "group": "数据与缓存",
    },
    "Flag-1075": {
        "name": "培养方案查看器",
        "desc": "解密 assets/curricula 下的加密 PDF 并在本机浏览器打开。",
        "group": "数据与缓存",
    },
    # ---------- 1080–1089 登录与会话 ----------
    "Flag-1080": {
        "name": "教务直连登录",
        "desc": "jw 模式：直接 POST 教务系统拿会话，通常无需验证码。",
        "group": "登录与会话",
    },
    "Flag-1081": {
        "name": "CAS 统一认证",
        "desc": "cas 模式：走统一身份认证，强制验证码，CASTGC 可静默续期。",
        "group": "登录与会话",
    },
    "Flag-1082": {
        "name": "传统登录",
        "desc": "vruc 模式：经 v.ruc.edu.cn 旧版授权链路换取教务会话。",
        "group": "登录与会话",
    },
    "Flag-1083": {
        "name": "会话恢复",
        "desc": "启动时尝试复用已保存的会话，避免每次重新登录。",
        "group": "登录与会话",
    },
    "Flag-1084": {
        "name": "退出登录",
        "desc": "清除凭据、停止监控并清空会话，保留成绩缓存。",
        "group": "登录与会话",
    },
    "Flag-1085": {
        "name": "验证码获取",
        "desc": "向教务请求验证码图片并支持点击刷新。",
        "group": "登录与会话",
    },
    # ---------- 1090–1099 后端监控 ----------
    "Flag-1090": {
        "name": "成绩自动监控",
        "desc": "后端循环按间隔查询成绩并比对增量。",
        "group": "后端监控",
    },
    "Flag-1091": {
        "name": "排名自动监控",
        "desc": "后端循环查询专业排名与班级排名变动，与成绩监控独立开关。",
        "group": "后端监控",
    },
    "Flag-1092": {
        "name": "监控时间窗",
        "desc": "仅在设定的起止时间内查询，窗外休眠。",
        "group": "后端监控",
    },
    "Flag-1093": {
        "name": "安全模式随机间隔",
        "desc": "在实际间隔 ±100 秒内随机取值，降低账号被风控的风险。",
        "group": "后端监控",
    },
    "Flag-1094": {
        "name": "首轮查询不等待",
        "desc": "首次查询完成后立即继续，不空等一个完整间隔。",
        "group": "后端监控",
    },
    "Flag-1095": {
        "name": "启动通知",
        "desc": "应用启动时发送一条就绪提示通知。",
        "group": "后端监控",
    },
}

# 全部默认开启：功能组开关是下线闸门，出厂不能有残缺。
DEFAULT_GATES: dict[str, bool] = {gid: True for gid in GATE_REGISTRY}


def _read_raw() -> dict:
    """读取原始 JSON；任何异常都返回空 dict（交由 load_gates 补默认值）。"""
    if not os.path.exists(GATES_FILE):
        return {}
    try:
        with open(GATES_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            logger.error("feature_gates.json 顶层结构异常，回退默认开关")
            return {}
        return data
    except Exception as e:
        logger.error(f"读取 feature_gates.json 失败，回退默认开关: {e}")
        return {}


def load_gates() -> dict:
    """返回完整功能组开关表（注册表全键 + 磁盘值）。

    只有磁盘上缺键（或值不是 bool）时才补默认并回写；内容完整时不写盘。
    """
    raw = _read_raw()
    gates = dict(DEFAULT_GATES)
    changed = False

    for gid, default in DEFAULT_GATES.items():
        if gid in raw and isinstance(raw.get(gid), bool):
            gates[gid] = raw[gid]
        else:
            changed = True

    # 磁盘上可能残留已下线的旧编号：忽略即可，不主动删除（保留回滚余地）
    if changed:
        try:
            atomic_write_json(GATES_FILE, gates)
            logger.info("feature_gates.json 已补齐缺失开关并回写")
        except Exception as e:
            logger.warning(f"回写 feature_gates.json 失败: {e}")

    return gates


def save_gates(gates: dict) -> dict:
    """整体覆盖写入；只保留注册表内的键，缺失键补默认值。"""
    payload = dict(DEFAULT_GATES)
    for gid, value in (gates or {}).items():
        if gid in payload and isinstance(value, bool):
            payload[gid] = value
    atomic_write_json(GATES_FILE, payload)
    logger.info(f"feature_gates.json 已写入（{len(payload)} 个功能组开关）")
    return payload


def set_gate(gid: str, value: bool) -> dict:
    """设置单个功能组开关并返回写入后的完整表；未知编号直接忽略。"""
    gates = load_gates()
    if gid in DEFAULT_GATES:
        gates[gid] = bool(value)
        gates = save_gates(gates)
    return gates


def _remote_overrides() -> dict:
    """远程下发的覆盖值（`feature_gates_remote.json`）。

    延迟导入：`remote_gates` 反过来依赖本模块的 `DEFAULT_GATES`，模块级导入
    会形成循环。这里只在真正取开关时导入一次，之后走 Python 的模块缓存。
    任何异常都按"无远程覆盖"处理——远程层不该拖垮本地功能。
    """
    try:
        from backend.storage.remote_gates import load_remote

        return load_remote()["gates"]
    except Exception:
        return {}


def gate_enabled(gid: str) -> bool:
    """读取单个功能组开关（本地值叠加远程覆盖）。

    未知编号视为**开启**（与 `flags.flag_enabled` 相反）：业务代码里写错一个
    编号不应该把功能静默吞掉，宁可失效也不要造成"功能凭空消失"。

    优先级：远程覆盖 > 本地 feature_gates.json > 默认 True。
    """
    overrides = _remote_overrides()
    if gid in overrides:
        return bool(overrides[gid])
    return bool(load_gates().get(gid, True))


def registry_payload() -> list[dict]:
    """注册表 + 当前生效状态，供 GET /api/features 与桌面表生成使用。"""
    gates = load_gates()
    gates.update(_remote_overrides())
    return [
        {
            "id": gid,
            "name": meta["name"],
            "desc": meta["desc"],
            "group": meta["group"],
            "enabled": gates.get(gid, True),
        }
        for gid, meta in GATE_REGISTRY.items()
    ]
