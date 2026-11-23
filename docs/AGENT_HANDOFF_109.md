# GradeMonitor for RUC 9：后续智能体交接文档

> 适用基线：`109.0.0+100`（桌面安装包版本显示为 `109.0.0.100`）
>
> 本文是协作说明，不是用户文档。开始改动前请先读完本文，并以当前代码为准。不要从本文复制或推断任何凭据、私钥或令牌。

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

- Flutter 版本源：`frontend/pubspec.yaml`，当前应为 `109.0.0+100`。
- Windows 文件版本：`frontend/windows/runner/Runner.rc` 与 `.data/setup.iss`。
- macOS DMG 命名由 `scripts/build_dmg.sh` 根据 `pubspec.yaml` 生成。
- 以后每次发布都要同时递增用户可见版本与 build number；不要只改其中一个。
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
- 卡片是白底、轻阴影；输入框透明、约 24px 圆角矩形，有浮动标签；聚焦时蓝色描边、普通状态灰色描边。
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
../scripts/inject_backend_macos.sh build/macos/Build/Products/Release/GradeMonitor.app
# 版本号取 pubspec.yaml 的 version，把「+」替换为「.」；例如 109.0.1+115 → 109.0.1.115
../scripts/build_dmg.sh /tmp/gm_signed/GradeMonitor.app 109.0.1.115
```

说明：

- `inject_backend_macos.sh` 必须显式传入 Flutter 构建出的 `.app` 路径；它会将便携式 Python 后端和 Keychain helper 注入其中，并把已签名的干净包输出到 `/tmp/gm_signed/GradeMonitor.app`。不能遗漏，否则安装后监测功能无法正常运行。
- `build_dmg.sh` 必须显式传入这个 `/tmp/gm_signed/GradeMonitor.app` 和四段版本号；版本号由 `pubspec.yaml` 的 `x.y.z+build` 改写为 `x.y.z.build`。不要以仓库（iCloud Drive）内的 `.app` 作为发布输入，iCloud 的扩展属性会破坏签名。
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
