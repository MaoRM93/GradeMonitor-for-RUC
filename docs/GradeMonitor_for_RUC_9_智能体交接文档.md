# GradeMonitor for RUC 9：后续智能体交接文档

> 核对日期：2026-11-18。当前源码基线为 `109.0.0+207`，对应桌面安装包 109.0.0.207。本文把用户要求、当前实现和已知验证缺口分开记录。
>
> 本文是协作说明，不是用户文档。开始改动前请先读完本文，并以当前代码为准。不要从本文复制或推断任何凭据、私钥或令牌。

## 第一次接手：按这个顺序读

1. 在仓库根目录运行 `git status --short`。当前设计改动有不少尚未提交，字体、SVG 和共享开关也可能显示为未跟踪。读取磁盘上的文件，不能只读 Git HEAD，更不能清掉这些文件。
2. 打开 `frontend/lib/main.dart`，找窗口尺寸、主题控制器和根组件。默认窗口是 1100×720，最小 900×600；侧栏占 212 个逻辑像素。截图如果来自 Retina，不能直接拿截图像素作为 Flutter 尺寸。
3. 打开 `frontend/lib/core/theme/app_theme.dart`，读 `ThemePreset`、`AppTheme.themeFor` 和 `ThemeController`。再从 `frontend/lib/views/navigation/app_navigation.dart` 找到对应页面。
4. 按下面的页面验收步骤复现问题。改完逐条说明哪些经过测试、哪些只做了代码核对。单测通过不等于在真实 macOS 窗口里看过一遍。

## 设计规则与对应代码

### 颜色、卡片和组件

- Material 3 Expressive 在这个项目里首先是**分组的形状和层级**。一组多项，每项各自绘制有底色的无边框圆角容器。组内留 2dp 露出页面底色，组间通常留 12–16dp。竖组首项上角 24、下角 4，中项四角 4，末项上角 4、下角 24，单项四角 24。水平组把外侧大角转到左右。截图标红指大角，标蓝指小角。
- 查 `settings_page.dart` 的 `_SegmentedSettingsGroup` 和 `_SegmentedSettingsItem`。组内子项必须横向拉伸；只给内部内容对齐，无法修复深色模式整张色块变窄。仪表板底部五格看 `dashboard_page.dart` 的 `_StatSegment`，仅最左外侧、最右外侧用大角，跟顶部卡的大角尺度一致。
- 主题负责页面底色和不同层次的容器色，检查 `scaffoldBackgroundColor`、`surface`、`surfaceContainerHighest` 和文字 `onSurface`。曾把最高容器色直接设成页面背景，结果两种亮度下卡片像消失。检查运行时实际消费的颜色，别只修改色表里一个未被使用的字段。
- 全局开关统一用 `frontend/lib/widgets/expressive_switch.dart`，包括设置、欢迎页监控项和通知转发。轨道宽高约 1.625∶1，关闭滑块约轨道高的 52%，开启约 78%。关闭无图标，打开有主题色对勾。关闭态轮廓和滑块需在浅深模式都明显，几何相对轨道高度计算。核对 `Switch.adaptive`、`SwitchListTile` 等调用是否漏迁；保留所有原有回调与禁用状态。

### 主题、侧栏和字体

- 色卡按人大红、冰川蓝、鼠尾草绿、典雅灰、古檀褐、经典蓝排序。人大红是无已保存偏好时的默认主题；升级保留已有选择。旧偏好键仍对应原预设，不能仅因显示名称变化就改存储 ID。设置页「显示效果」只放带名称的色卡和深色模式三项（启用、关闭、跟随系统），两个色块左右等宽。欢迎页主题选择只保留标题、色卡名和显示模式控件，删除灰色描述。
- 侧栏标识用 `frontend/assets/grade_monitor_logo.svg`，居中放在顶部并留白。五个入口作为整体上移，底部 Release 单独沉底居中。人大红整栏铺红，各主题统一 212dp；`_LogoColorMapper` 控制 i 的点，人大红用浅金，正文墨色随深浅模式反相。
- 页面大标题和章节名用思源宋体，并加重。查 `pubspec.yaml` 的字体注册、`AppTheme` 和页面显式 `TextStyle` 三处。全局标题目前设有 w900，但字体清单只有 Regular，单改 w900 不能保证肉眼或实测字重恰好增粗 25%。若继续修这一项，要核对真实重字重资源与实际渲染。搜索框、下拉框、表格、说明小字保留默认无衬线。仪表板最新成绩卡主标题和方案页「核心绩」「计算结果」属于标题。
- 文案以用户给出的字样为准。避免装饰性编号、代替真实功能的解释、额外灰字、随手画出的装饰图标和卡片框线。功能控件的必要标签、状态与错误信息应保留。

### 成绩单：从截图定位到测试

1. 打开 `frontend/lib/views/grades/grades_page.dart`，查搜索、`_filterControl`、学期/范围下拉和核心指标。最新截图要求搜索独立一行，下一行学期、范围居左，核心课数和核心绩在范围右侧，文字垂直居中。搜索与两个选单可见外框等高、同圆角。测试真实有效区域，不能用外层 SizedBox 高度推断输入装饰实际高度。
2. **当前源码的已知缺口**：固定筛选行仅在可用宽度达到 980dp 时启用；默认窗口扣掉侧栏 212 与两侧内边距 56 后只有约 832dp，会进入 Wrap 分支。当前学期文字设为单行省略。再修时以默认 1100 窗口验收，不要仅放大窗口截图。可先测完整最长学期名（含字体缩放）、下拉箭头及内边距所需宽度，再分配范围框和核心统计剩余空间。
3. 浅色和深色下实际打开两个下拉，检查已选文字、列表文字、背景对比和弹层尺寸。选中最长学期后检查折行、截断、筛选逻辑与核心统计。核对禁用可选搜索功能时是否留下无用占位。
4. `_buildExtractionCalculator` 与 `_showCalculationSemesterDialog` 是抽取计算入口。弹窗里用临时集合多选，取消和点外侧关闭应保留之前的结果，确认后才在本地重算。测试两个学期、清空选择和取消。核心课程口径查 `views/scheme/scheme_core.dart`，不要把各学期 GPA 简单平均，保持现有学分加权及 PF 制排除规则。
5. 学期卡只显示学期名和一行摘要「x门，x学分，绩点：xxx」。截图的整组外轮廓才用大角。上面抽取计算条的顶部两角也有红标，底部两角是蓝标；当前抽取条仍是统一圆角，首末学期卡的大角也需要按整组外轮廓核对。现有 `grades_layout_test.dart` 检查表格等宽与学期统计，不能替代筛选行几何测试。

### 欢迎页：检查转场顺序

在 `welcome_flow.dart` 从 `_goto` 读起。207 使用单个页面转场控制器，旧页先退场约 300ms，随后切换步骤，新页再横向进入约 460ms。进入步骤的加载逻辑仍在页面切换后触发。保持单页挂载的顺序，避免恢复叠放两页的 AnimatedSwitcher。测试前进、返回、快速连按和异步加载界面。实际卡顿应在 macOS profile/release 检查帧表现，尤其是有验证码、Markdown、背景动效的步骤。静态分析和成绩单测试都无法证明动画帧率。

### 其他容易误改的边界

- 「撤回通知」改为「关闭通知」是 UI 换词，查 `developer_options.dart` 的按钮和确认框；底层业务语义沿用。红、蓝提示页图标需和顶部留足距离。
- 通知转发各渠道保留各自启停、保存、测试。ntfy 在 `backend/service/forwarder_service.py` 用主题 URL 加纯正文 POST。验收应检查手机实际通知正文，避免把包含 title 等字段的 JSON 当正文直接显示。测试只用授权的测试主题，日志不要输出实际主题或其他凭据。

## 1. 项目目标与目录

这是一个 Flutter 桌面客户端加本地 Python/FastAPI 后端的成绩监测程序。

```
frontend/                    Flutter 客户端
backend/                     本地 FastAPI 服务、成绩监测与开发者控制接口
scripts/                     签名、课程方案加密、macOS 注入后端与 DMG 打包脚本
docs/                        协议及交接文档
```

核心职责的分界：

- 客户端负责 UI、账号登录、显示、远程 Release 读取、签名验证、系统通知和转发配置。
- 本地后端负责成绩轮询、转发执行、开发者认证会话、受保护的签名操作，以及与 GitHub Release 的写入。
- GitHub Release 是公开的分发与签名控制载体，不应在其中保存任何私密令牌、私钥、真实开发者密码或用户个人数据。

## 2. 当前版本与版本号规则

- Flutter 版本源：`frontend/pubspec.yaml`，当前为 `109.0.0+207`。
- Windows 文件版本：`frontend/windows/runner/Runner.rc` 与 `.data/setup.iss`。
- macOS DMG 命名由 `scripts/build_dmg.sh` 根据 `pubspec.yaml` 生成。
- 同一发布系列通常保持 `109.0.0`，递增 build number，并同步 Windows 文件显示版本及 DMG 文件名。检查应用 Info.plist 里短版本和构建号两项。
- 新的 109 信任链与旧版本不兼容。旧客户端不能自动升级到采用新签名密钥的 109 版本，这是预期行为；首个 109 版本需要手动安装。

## 3. 开发者模式：设计意图与不可破坏的约束

开发者菜单位于设置页，默认隐藏。用户在设置页底部连续点击版本号五次后，完成开发者身份验证，菜单才会出现。

- 成功登录后，`UiPrefsService.prefDevPanelPinned` 会把“在此设备展示开发者选项”持久化。
- 此状态不会自动关闭；只有开发者菜单中的“关闭开发者选项”总开关应清除它。
- 这只是本机 UI 可见性，不是授权本身。每一次敏感后端请求都必须继续经过开发者认证。
- 不要把开发者密码、PAT、签名私钥、Bearer token 或其可逆形式硬编码进 Flutter、Python、配置文件、日志、Release 或测试夹具。
- 不要为了方便调试加入绕过鉴权、跳过签名验证、隐藏开关后门或默认开发者登录。

相关文件：

- 前端登录入口：`frontend/lib/views/navigation/developer_login_dialog.dart`
- 前端菜单：`frontend/lib/views/settings/developer_options.dart`
- 本机可见性偏好：`frontend/lib/core/service/ui_prefs_service.dart`
- 后端认证：`backend/service/developer_auth.py`
- 后端路由：`backend/api/app.py`

## 4. 远程功能开关（Feature Gates）

### 4.1 基本模型

远程控制采用**签名的配置块**，存放为专用 GitHub Release，而不是作为普通应用更新。

- 后端真源：`backend/storage/remote_gates.py`
- 本地 flag 映射：`backend/storage/flags.py`、`backend/storage/feature_gates.py`
- 前端读取与校验：`frontend/lib/core/service/feature_gate_service.dart`
- 前端更新/Release 读取：`frontend/lib/core/service/update_service.dart`
- 协议说明：`docs/DEV_FLAGS_CONTRACT.md`

控制 Release 的标签格式是 `control-v<revision>`。普通更新检查必须排除：

- `control-v...`：远程功能控制；
- 纯通知/固定通知标签；
- pre-release；
- 无有效应用资产或不适合作为应用升级的条目。

绝不能恢复早期依赖 `114` Release 标签三击或标签探测的实现。`114` 仅保留为一个可远程控制的业务 flag；禁用它只影响其自身触发条件，不能影响蓝屏、红屏或开发者控制台的显示逻辑。

### 4.2 发布时序（极其重要）

下发功能开关时，必须遵守：

1. 前端编辑的是草稿，不应直接修改本地已生效的远程状态。
2. 后端根据当前完整远程快照构造新配置、签名并上传/更新 GitHub Release。
3. 仅当 GitHub 返回成功后，才把新状态保存为本机已发布状态并向前端返回成功。
4. 网络失败、GitHub 返回 4xx/5xx 或签名失败时，必须保留旧状态并明确报错。

不要把“点击 Apply”视作下发成功。不可将本地立即生效与远端成功混为一谈。

### 4.3 保护 flag

受保护 flag 是业务与恢复路径的关键开关。UI 和后端都必须拒绝改变它们，不能只依赖灰色按钮。

当前保护列表：`1051、1042、1070、1071、1085、1084、1063、1066、1060、1074、1001`。

若确需改变保护列表，要同时审查：前端禁用、API 校验、后端合并逻辑、控制配置协议和恢复方案。不要删掉其中任一层。

### 4.4 轮询限制

远程控制或本地工具涉及的轮询秒数必须夹在 `60` 到 `86400` 之间。前端校验只是体验层，后端也必须校验，防止构造请求绕开界面。

## 5. 签名、钥匙串与发布安全

项目现在有相互独立的用途密钥：

- 应用更新签名；
- 远程控制配置签名；
- 广播通知签名。

私钥不在仓库中，应该从当前 macOS 开发机的 Keychain 读取。访问代码：

- Swift 访问器源码：`scripts/keychain_secret.swift`
- 随便携后端携带的二进制：`backend/bin/keychain_secret`
- Python 调用封装：`backend/storage/signing_keys.py`
- 普通敏感凭据访问：`backend/storage/credentials.py`

安全要求：

- 不要重新创建 `.pem` 私钥文件、Base64 私钥常量或私钥备份到仓库。
- 不要在 shell 命令行参数中传递密钥或 PAT；命令行历史、进程列表和日志都可能泄露它们。
- 不要把“远程 flag”设计成跳过更新签名校验的开关。更新包签名始终要验证。
- 修改 Keychain helper 后，必须验证它仍按预期要求用户授权、不会以纯文本 fallback 降级。
- macOS 之外无法安全读取 Keychain 的场景，应明确失败，不能悄悄降级为源码内或磁盘明文凭据。

## 6. 广播通知、蓝屏与红屏

开发者选项中的“广播通知”模块支持三个互斥渠道：

- `Default_Notice`：普通右上角通知，允许 Title 和 Body。
- `Important (BL)`：蓝屏/重要提示，仅允许 Body。
- `Disable (RE)`：红屏/服务停用提示，仅允许 Body。

前端实现：`frontend/lib/views/settings/developer_options.dart`。
后端发布接口及签名封装：`backend/api/app.py`。
客户端接收、筛选和验证：`frontend/lib/core/service/update_service.dart`、`frontend/lib/core/service/update_verifier.dart`、`frontend/lib/views/disabled/`、`frontend/lib/views/notice/`。

交互要求不能退化：

- 未选渠道时文本框和按钮灰置。
- 默认通知 Title/Body 都必填；蓝屏/红屏只允许填写正文。
- Preview 只预览，不下发。
- Send 是红色、带纸飞机图标，点击后必须二次确认。
- 成功或失败通过 toast 给出结果；不可伪造“成功”。
- 任何实际 GitHub 写入失败都不能令本机提前显示已下发效果。

蓝屏、红屏和普通通知与 `114` flag 相互独立。维护时尤其注意不要错误建立依赖。

## 7. 通知转发页面

页面：`frontend/lib/views/forwarders/notification_forwarders_page.dart`。
后端转发：`backend/service/forwarder_service.py`、`backend/service/notification_service.py`。

支持三个免费渠道：

- Bark：iPhone/iPad；
- Meow：HarmonyOS；
- ntfy：Android。

UX 约束：

- 三个渠道独立卡片、独立保存按钮和独立测试按钮；未保存前测试应不可用。
- 保存后的文本不能因路由切换而清空。
- 转发页现有卡片样式单独查看页面源码；若被要求改为全局 Expressive 风格，沿用主题色层级与无边框分段规则。输入框仍需要可见的交互状态。
- 不能把全局“保存设置”按钮或明显的 AI 式灰色说明文案带回来。
- 平台 SVG 资产在 `frontend/assets/Apple_Logo_Blue.svg` 与 `frontend/assets/nearlink.svg`；Android 使用同尺度图标。

## 8. 培养方案查看与内容保护

入口位于方案计算页：`frontend/lib/views/scheme/`。

- 用户仅可查看账号前四位年份对应的培养方案，例如 `2025xxxxxx` 只能选择 2025 级。
- 源 PDF 经过脚本加密处理，运行时由应用解密后交给浏览器查看。
- 相关脚本：`scripts/encrypt_curricula.py`；后端服务：`backend/service/curriculum_service.py`。
- 不要把明文 PDF、解密密钥或可直接下载的未保护文件放进公开 Release。
- 用户侧提示使用中性、合法的网络表述，例如“如无法打开，请检查网络连接”；不要写不必要或不当的规避性建议。

## 9. GitHub Release 请求节流

`frontend/lib/core/service/update_service.dart` 维护 Release 列表的短期缓存、in-flight 去重和过滤逻辑。更新检查、通知检查、蓝屏/红屏检查及控制配置读取应尽可能复用同一份列表，避免匿名 GitHub API 限额。

修改时请保持：

- 不要为每个固定标签分别发一次 GitHub 请求；
- 不要把控制 Release 误判为新版本；
- 失败时不要清空上一份仍有效的缓存；
- 缓存时长与刷新逻辑要能在“及时性”和“限额”间平衡。

如未来控制/通知 Release 数量明显超过单页结果，必须再设计分页或专用索引；不要悄悄删除过滤逻辑来掩盖问题。

## 10. 构建、验证与 macOS DMG 打包

常用命令从仓库根目录执行：

```sh
cd frontend && flutter pub get
cd frontend && flutter analyze
cd frontend && flutter test
cd frontend && flutter build macos --release
```

从仓库根目录调用打包脚本的形式是 `./scripts/build_dmg.sh <app路径> <四段版本号> [输出路径]`。先核对后端注入脚本的用法和构建产物是否已经注入，确认包中有后端运行时。对照桌面 200 版，卷内应用必须是 `GradeMonitor.app`，包标识 `com.grademonitor.app`，含背景与 Applications 快捷方式，Finder 可按拖拽布局安装。别拿带版本后缀的临时 .app 直接作为镜像内容。复制到普通临时目录再校验签名可避免 iCloud 给框架附加 Finder 元数据。发布前挂载产物，核对名称、版本、架构、签名和卷内布局。

把打包、卸载和清数据分别理解。仅修改代码时不做发版操作。用户要求卸载才处理已确认的应用路径，明确要求清除才处理应用数据。先查 Application Support、偏好、缓存和沙盒容器；开发签名资料属于独立资产，不能把名称相似当作删除依据。受 macOS 保护的容器若只剩系统登记，照实记录。桌面 200 版是用户恢复的参照包。

说明：

- `inject_backend_macos.sh` 会把便携式 Python 后端和 Keychain helper 注入 macOS 应用包；不能遗漏，否则安装后监测功能无法正常运行。
- `build_dmg.sh` 从当前版本号产生桌面 DMG。每次构建前确认旧 DMG 的删除范围，绝不使用宽泛的删除命令。
- 如用户明确要求“清理缓存、卸载旧版、删除旧 DMG”，必须先确认精确路径，再使用可审计的范围进行清理。
- 发布前至少运行与变更相关的 Flutter/Python 检查；涉及签名、控制下发或安装包时，要额外验证失败路径不会改变本地状态。

## 11. 提交与发布边界

- 提交代码、推送 GitHub、创建 GitHub Release、上传 DMG 是四个不同动作。除非用户明确授权，不要把它们混在一起。
- 新 Release 的更新说明应参照已有 Release 的中文语气；大版本可用“您期待的 GradeMonitor for RUC 9 来了！”作为卷首语。
- 不能在没有有效签名和可验证资产的前提下发布可被客户端当作更新的 Release。
- 推送前查看 `git status --short`，避免误提交构建产物、缓存、私密文件和用户本机数据。

## 12. 修改前检查清单

1. 阅读本文、`docs/DEV_FLAGS_CONTRACT.md` 和受影响文件。
2. 搜索已有实现，避免做出第二套相同逻辑。
3. 敏感控制必须前端、后端、签名验证三层都检查。
4. 网络调用必须区分真正成功与失败，特别是 4xx/5xx。
5. 不记录凭据，不降低签名校验，不添加绕过入口。
6. 修改后做最小但相关的验证；若用户要求不测试或不打包，要尊重该范围。
7. 报告事实、文件与验证结果，不把未验证的推测说成完成。

## 13. 仍需留意的技术边界

- GitHub Release 作为免费控制通道有公开可见、速率限制和分页限制；签名保护的是完整性，不等同于保密。
- 远程“禁用”只适合控制程序自身的可选功能，不可作为安全边界或数据销毁机制。
- 任何“撤回”式控制都依赖客户端下一次成功轮询，无法保证离线设备立即响应。
- 代码中的 UI 保护不能替代后端拒绝、签名验证和 Keychain 权限。

维护本项目时，优先保证：用户成绩与凭据安全、更新链完整、控制下发的真实结果可追溯，以及失败不改变生效状态。
