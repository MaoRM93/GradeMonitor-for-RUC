# 开发者开关（Developer Flags）实现契约

> 本文件是三个并行改造任务的共享契约，任何一方不得单方面改名。
> 建立时间：2026-11-16

## 1. 存储

- 文件：数据目录下 `feature_flags.json`（`get_data_file_path("feature_flags.json")`）
- 模块：`backend/storage/flags.py`
- 结构：扁平 `dict[str, bool]`，键名即 Flag 名，值即开关状态
- 读：缺失键用 `DEFAULT_FLAGS` 补齐并回写；文件损坏时回退默认值
- 写：整体覆盖 + 原子写（复用 `backend.storage.cache.atomic_write_json`）

## 2. 本机 Flag（显示于「功能遥测」）

| 编号 | Flag 键 | 按钮文本 | 默认 | 含义 |
|---|---|---|---|---|
| 1.1 | `Enable_PYFA_EvyGrde` | `1.1 Enable_PYFA_EvyGrde` | 关 | 解除方案计算页对账号年级的匹配限制，展示全部年级培养方案入口 |
| 1.2 | `Show_Feature_0A1B` | `1.2 Show_Feature_0A1B` | 关 | 空开关，预留 |
| 1.3 | `Enable_Feature_1A2C` | `1.3 Enable_Feature_1A2C` | 关 | 空开关，预留 |
| 1.4 | `Enable_Feature_2B3D` | `1.4 Enable_Feature_2B3D` | **开** | 空开关，预留 |

## 3. 功能遥测与远程控制

开发者 UI 只显示 Flag 编号，不展示功能名称或描述。本机 Flag 与 `Flag-1xxx`
功能组开关均在此分组内展示；其中受保护编号 `1001、1042、1051、1060、1063、
1066、1070、1071、1074、1084、1085` 只能查看，前后端均拒绝修改。

## 4. 按钮样式规范

- 组件：`OutlinedButton`
- 关闭态：边框 `#9CA3AF`（灰）、文字 `#9CA3AF`、无填充
- 开启态：边框 `AppTheme.success`、文字 `AppTheme.success`、无填充
- 按钮文本恒不变，只有颜色变化
- 尺寸：高度 36，`padding` 水平 14、垂直 0，`borderRadius` 10，`fontSize` 13，`fontWeight w600`
- 排列：`Wrap(spacing: 8, runSpacing: 8)`

## 5. 后端接口

- `GET /api/developer/flags` → `{"flags": {<全部键>: bool}}`
  - 不需要开发者解锁（方案计算页等业务页面要读开关）
  - 仍受本地 API 令牌中间件保护
- `POST /api/developer/flags` → body `{"name": "<flag>", "value": true}`
  - 需要开发者解锁（`_require_developer()`）
  - 返回 `{"success": true, "flags": {...}}`
- `_require_developer()` 的**唯一**判据：`backend/service/developer_auth.is_authenticated()`
  —— 系统钥匙串 / DPAPI 里存着一个经 `GET https://api.github.com/user` 验证过
  归属的 GitHub 令牌，且其数字 `id` 命中内置管理者注册表。
  settings.json 的任何布尔值都不再参与鉴权（那个字段已废弃并会被主动丢弃）。

## 6. 培养方案（1.1 关联改动）

- `backend/service/curriculum_service.py`
  - `grade_for_current_user()` 保持原样（账号匹配 + 403 语义不变）
  - 新增 `available_grades() -> list[str]`：返回 `assets/curricula/*.pdf.enc` 实际存在的年级，升序
  - `open_curriculum(grade: str | None = None)`：`grade is None` 时走原账号匹配逻辑；
    显式传年级时仅在该年级存在于 `available_grades()` 中才放行
  - `view_curriculum(grade, access)`：一次性 token 里已记录 grade，账号一致性校验改为
    「Flag `Enable_PYFA_EvyGrde` 开启 或 与当前账号年级一致」
- `POST /api/curriculum/open` body 可选 `{"grade": "2025"}`；不传时行为与现在完全一致
- 前端 `frontend/lib/views/scheme/scheme_page.dart`
  - Flag 关：保持现有单按钮与禁用逻辑，一字不改
  - Flag 开：改为每个可用年级一个按钮，文本 `查看 {grade} 级培养方案 ↗`，全部可点

## 7. 不做的事

- 不修改 `SettingsUpdate` 字段集合（Flag 走独立文件，不进 settings.json）
- `GRADEMONITOR_DEVELOPER_PASSWORD` 已废弃：前端拉起后端时从来只注入
  `GRADEMONITOR_APP_PATH` 与 `GRADEMONITOR_API_TOKEN`，没有任何注入点，
  所以发行版里那条解锁路径恒 503。开发者身份改由 GitHub 令牌判定。
- 不改动 811 / 82 计算口径、白名单、PF 剔除规则

## 8. 远程下发（Flag-1xxx 功能组）

- 通道：GitHub Release tag `control-v<rev>`，正文内一块 `gm-gates-v1` 签名块；该频道不参与应用更新检查
- 客户端只读（匿名），写入必须持有开发机钥匙串中的专用控制私钥；更新/通知签名密钥与控制密钥完全分离
- 拉取节奏：启动时 + 每小时（复用既有 `_gate_refresh_loop`）
- UI 只提交本次改动；服务端将已有远程覆盖与该改动合并、签名为完整快照。发布失败不改本机生效值；拉不到时保持现状。
- 防回滚：`rev` 必须严格递增，小于等于本地已应用 rev 的指令整包忽略
- 验签失败：整包丢弃，并保留上一次成功应用的覆盖值
- 未知 gate id：静默忽略（新客户端加了 gate、旧客户端还不认识它）

## 9. 远程通知（蓝屏 / 红屏 / 广播 / 114 关停）

四条通道全部改为**签名制**，正文里必须带一块 `gm-notice-v1`：

```text
gm-notice-v1
kind=red|blue|broadcast|disable114
tag=<该 Release 的实际 tag>
sha256=<去掉签名块后正文的 SHA-256，小写 hex>
sig=<Ed25519 分离签名 base64，64 字节>
```

- 被签名的原文 = 该块除 `sig=` 行以外的全部行，`\n` 连接后补一个 `\n`
- 客户端校验：`kind` 匹配通道、`tag` 匹配实际 tag、`sig` 用内置公钥验过、
  `sha256` 等于正文摘要 —— 四条全过才认这条通知
- 验签不通过 → 当作「未知」而非「已删除」：既不弹屏，也不误清已生效的停用态
- 发布方式：`scripts/publish_notice.sh`（本机终端，私钥 + `GITHUB_TOKEN`）
- 客户端内的「控制台」卡片与 `/api/developer/console` 端点已删除
