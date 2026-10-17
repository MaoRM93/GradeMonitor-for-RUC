# GradeMonitor — 适用于 RUC 教学系统的成绩自动监控工具

**Bug说明：用户反馈在 macOS 15.6 及更低版本的系统下无法弹出通知，这是因为您没有更新最新版本的 macOS 。请您前往 设置 - 通用 - 软件更新 中检查并安装系统更新。目前 macOS 26 和 27 均无此问题。
用户反馈在 Windows 10 上会偶发第一次启动应用时前台界面无法及时拉起后端服务的情况，这可能与您的操作系统版本有关。请更新到 Windows 11 以解决此问题。**

GradeMonitor（原名 Grade Detector） 是一款适配 **macOS 与 Windows** 的成绩排名自动检测工具，安装后根据你的设置默默在后台工作，出分了就发通知告诉你，省下大把刷网页的时间。

<img width="700" height="200" alt="image" src="https://github.com/user-attachments/assets/c174b384-67ee-4865-87a5-0dbb89d0fa63" />

## 它是怎么工作的？

本程序会按照你设定的时间间隔，自动登录教务系统查询成绩和排名。

一旦检测到**新出成绩**或**排名变化**，立即通过系统原生通知推送到你的桌面。

也支持简洁模式！仅提示「您有成绩或排名更新」这几个字，保护隐私，保护心灵。

## 核心功能一览

### 自动监测
- 支持**成绩监测**和**排名监测**，可独立开关
- 可设定监测时间窗口（如 08:00–23:00），深夜不打扰，窗口外自动休眠
- 监测间隔可自定义（300–3600 秒），避免对学校服务器造成过大负担

<img width="2200" height="1440" alt="image" src="https://github.com/user-attachments/assets/525e0980-2d22-42c4-8350-cc2c9baa640e" />

### 通知推送
- **详细模式**：直接在通知中显示课程名、绩点、专业排名、班级排名变化
- **简洁模式**：仅提示「您有成绩或排名更新」，保护隐私

### 排名可视化
主界面实时展示**专业排名**和**班级排名**，无需登录教务系统即可查看。

### 更新检查
内置应用更新检查（在设置页手动触发），发现新版本时提示并引导前往 GitHub Releases 下载。启动时的静默联网检查仅用于获取远程可用性开关，不会上传任何数据。

### 其他特性
- **托盘图标**：在系统托盘（Windows）或顶部菜单栏（macOS）显示小图标，点击可快速打开主界面或退出程序，可在设置中开关
- **深色模式适配**：自动跟随系统深色/浅色模式切换，夜间使用不刺眼
- **开机自启动**：macOS 通过系统登录项实现（可在「系统设置 → 通用 → 登录项与扩展」中管理）

## 如何使用？

### Windows 端

1. 下载最新版安装程序 `GradeMonitor_107.0.0.xxx_Windows_x64.zip`，解压后双击运行exe安装包，按向导完成安装（无需管理员权限）
2. 启动 GradeMonitor，在设置页填写学号和密码（可勾选记住密码）
3. 勾选需要监测的项目，设置时间范围和间隔
4. 点击「启动自动监控」，然后关闭窗口——程序会在后台默默工作
5. 等待通知
> 关闭窗口不会退出程序。如需彻底退出，请通过系统托盘图标选择「退出」。

### macOS 端

1. 下载 `GradeMonitor_107.0.0.xxx_macOS_AppleSilicon.zip`，解压后将 `GradeMonitor.app` 拖入「应用程序」文件夹
2. 首次打开，请打开「应用程序」文件夹或 启动台 ，右键点击 App → 选择「打开」，确认运行
3. 在界面上方填写学号和密码（可勾选记住密码）
4. 勾选需要监测的项目，设置时间范围和间隔
5. 点击「启动自动监控」，然后关闭窗口——程序会在后台默默工作
6. 等待通知
> 关闭窗口不会退出程序。如需彻底退出，请通过菜单栏图标选择「退出」或按 `Command + Q`。

## 源码

本仓库为 **Windows / macOS 双平台单代码库**：`frontend/lib` 与 `backend` 为两端共享，平台差异分别位于 `frontend/windows` 与 `frontend/macos`。

### 技术栈

| 层 | 技术 |
|---|---|
| 桌面前端 | Flutter（Windows / macOS 共享一套 `frontend/lib`） |
| 本地后端 | Python FastAPI + uvicorn（`127.0.0.1:18923`） |
| 更新分发 | GitHub Releases |
| 源码仓库 | [MaoRM93/GradeMonitor-for-RUC](https://github.com/MaoRM93/GradeMonitor-for-RUC) |

### 构建前端

```bash
# macOS（.app）
cd frontend
flutter pub get
flutter build macos --release
# 产物：build/macos/Build/Products/Release/GradeMonitor.app

# Windows（需在 Windows 机器上构建）
flutter build windows --release
# 产物：build/windows/x64/runner/Release/
# Inno Setup 打包脚本见 .data/prepare_staging.py + .data/setup.iss
```

### 启动后端（本地开发）

```bash
pip install -r backend/requirements.txt
uvicorn backend.api.app:app --host 127.0.0.1 --port 18923
```

### 版本号体系

- 完整版本：`107.0.0.135`（`frontend/pubspec.yaml` 中 `version: 107.0.0+135`）
- 发行状态：`Release`（正式版）/ `Beta`（测试版），由 `frontend/lib/core/service/update_service.dart` 中的 `VerStatus` 常量控制，发布时手动更新
- 更新检查指向的仓库：`MaoRM93/GradeMonitor-for-RUC`（同上文件中的 `repoOwner` / `repoName` / `repoUrl` 常量，GitHub 仓库更名后需同步修改）

## 系统要求

- macOS 13 及以上（仅 Apple Silicon / M 系列芯片）；推荐最新版：macOS 27.0.1
- Windows 10 64位，版本 1809 及以上（x64）；推荐最新版：Windows 11 26H2

## 注意事项与免责声明

### 请严格遵守学校管理规定
本工具的本质是代替你手动登录教务系统查询成绩，并不是任何形式的非法手段。请确保你的使用行为符合学校相关规定。

### 请积极参与评教
虽然本程序可以让你在没有评教的情况下也看到平时和期末成绩的分数，但是请按时完成评教，以免影响成绩查看。作者强烈反对您偷懒不去评教。

### 请勿攻击服务器
严禁将监测间隔设置为极短时间（如低于 60 秒），严禁使用本工具对学校服务器发起高频请求或任何形式的攻击行为。请在设置中保持合理的查询间隔（建议 300 秒以上），善待学校服务器。

### 免责声明
- 本工具为个人开发项目，与学校无关，非官方软件
- 使用本工具产生的任何后果（包括但不限于账号异常、成绩泄露、违反校规等）由用户自行承担，开发者不承担任何责任
- 本工具不收集、不上传、不分享用户的任何个人信息（包括学号、密码、成绩数据）。所有数据仅存储在您的本地设备
- 请妥善保管您的账号密码。如因密码泄露导致的问题，开发者不承担责任
- 本工具仅供个人学习与技术交流使用。请勿用于商业目的或分发给不可信第三方
- 开发者保留随时停止维护或修改本工具的权利
- 您下载使用本 App 则说明您已充分理解并同意本 Readme 文件中的上述条款与免责声明
