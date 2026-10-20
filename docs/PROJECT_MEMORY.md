# GradeMonitor 项目记忆（Project Memory）

> 供跨会话延续上下文。最后更新：2026-10-20 · 版本 107.0.0+150 · 环境 10-20 已彻底清场（v149 卸载 + 缓存/数据清零）

## 项目概览

- **双平台单代码库**（macOS + Windows 共用 Flutter 前端 + Python FastAPI 后端），基线合并自 `d9c0095`。
- 前端 `frontend/`（Flutter + Riverpod），后端 `backend/`（uvicorn, 端口 18923，仓库自带 `.venv`）。
- 应用数据目录：`~/Library/Application Support/GradeMonitor/`（settings.json、local_grades.json、local_ranks.json、stats.json、recent_change.json、logs/）。
- 版本策略：`107.0.0+<build>`；**每打包一次 build 号 +1**（当前 149）。

## 代码结构与关键文件

| 文件 | 职责 |
|---|---|
| `frontend/lib/views/welcome/welcome_flow.dart` | 全窗口 6 页向导（0 欢迎 → 1 法律声明(倒计时) → 2 账户 → 3 监控 → 4 通知 → 5 完成）。旧 `welcome_dialog.dart` 已删 |
| `frontend/lib/views/navigation/app_navigation.dart` | `_welcomePhase = checking/welcome/main` 三阶段门控；检查期同色遮罩防闪现；后端 10 次重试失败兜底进主界面 |
| `frontend/lib/views/dashboard/dashboard_page.dart` | 监控状态整行卡(88) → 最新动态整行卡(自适应) → 5 统计卡行(200)：GPA(小数34px) / 班级排名 / 专业排名 / 修读课程 / 查询次数 |
| `frontend/lib/views/grades/grades_page.dart` | 成绩单：搜索 + **学期筛选下拉** + 排序 DataTable（表头居中靠 `headingRowAlignment`） |
| `backend/service/notification_service.py` | `_show(title, message, record=True)`：真实通知写入 `recent_change.json`；测试/预览/启动提示 record=False |
| `backend/api/app.py` | `GET /api/grades/latest-change` 供仪表板"最新动态" |
| `frontend/assets/app_icon_tb.png` | 首屏图标：抠外透明(洪泛,内白保留) + 图形放大至画布 **95%** 宽。Pillow 环境：`PYTHONPATH=/tmp/pillow_tmp` |

## 用户铁律（必须遵守）

1. **没有明确要求，绝不碰 GitHub**：一切工作只在本地。本地 commit 可以；push / tag / release 必须先获得用户明确指令。
2. **每次打包新版本前，彻底清除上一版所有残留，包括已保存的登录信息**：
   ```bash
   rm -rf "/Users/admin/Library/Application Support/GradeMonitor"
   find ~/Library/Caches ~/Library/"Saved Application State" ~/Library/HTTPStorages ~/Library/Preferences -maxdepth 1 -iname "*grade*" -exec rm -rf {} +
   ```
   （zsh 通配符不匹配会中断整条命令，用 find，勿用裸 glob）
3. 图标一律**线条式** Material 图标（`*_outlined`/`*_rounded` 勾线类），**拒绝底色块**。
4. 设置页图标无底色，图形左缘与标题首字左缘对齐（墨迹偏移：person/notifications 10.4、settings 5.9、task_alt/balance 5.3 @64px，`_setupIcon(cs, icon, {inkShift})`）。
5. 布局：内容组整体居中、组内左对齐；默认 1100×720 一屏少滚动。

## 常用工作流

```bash
# 构建 + 交付（记得 build 号与文件名一致）
cd frontend && flutter analyze && flutter build macos --release
rm -rf /Users/admin/Desktop/GradeMonitor.app
cp -R build/macos/Build/Products/Release/GradeMonitor.app /Users/admin/Desktop/
ditto -c -k --keepParent /Users/admin/Desktop/GradeMonitor.app /Users/admin/Desktop/GradeMonitor-107.0.0.<N>-macOS.zip

# 后端冒烟（uvicorn 在系统 python 没有，必须用仓库 venv）
.venv/bin/python -m uvicorn backend.api.app:app --port 18999

# 图标资产重制（洪泛→放大→左贴，见 docs 内脚本历史；Pillow: PYTHONPATH=/tmp/pillow_tmp）
```

## 历史教训

- **stretch + 无界高度**：滚动视图 Column 内 Row 用 `crossAxisAlignment: stretch` → 子项被锁死无穷高（Center 内容跑 +∞，Release 静默无报错）。改固定高度 `SizedBox(height:)`。
- 洪泛抠图脚本若从**原始素材**重新导入会覆盖掉放大版——先抠后放大的顺序必须保持在同一脚本里。
- 欢迎页"不显示"多半是数据态（用户点完「好」→ welcome_completed=true）而非代码错；`show_welcome_always` 可用开发者面板（三击版本号）切换。

## analyze 基线

干净基线 ~12 条 info/warning 均为合并遗留（tray_service `_quitApp` 未用、settings_page `_prevShowMenubarIcon` 未用等），勿当新 bug 修。

## 2026-10-20 快照

- 曾推进 `107.1.0+150` beta.1（提交 `4eff701` **已在远程**），随后用户**有意回退**：本地提交 `d80d442` Revert（未推送）。CHANGELOG.md 已移除，版本停在 107.0.0+149。107.1.0 材料（CHANGELOG 文案）可从 `git show 4eff701:CHANGELOG.md` 找回。
- 清场记录（已完成）：`/Applications/GradeMonitor.app`、`Application Support/GradeMonitor`、Caches/Preferences/HTTPStorages 内 *grade* 残留、`Application Scripts/com.example.gradeMonitor` 全部删除，`flutter clean` 完成。`Containers/com.example.gradeMonitor` 仅剩 32K 系统 metadata（containermanagerd 保护，自动回收，无用户数据）。
- 今日更新（本地提交 `310181e` + 自更新功能提交）：① 统计卡字重 w600→w400、图标 22→44、文案 12.5→18.75（五张卡统一改，用户原话"四个"未细分）；② 更新弹窗：新增依赖 `flutter_markdown_plus 1.0.12`（md 渲染）+ 应用内直接下载（独立 Dio 通道下载到 ~/Downloads，.part 原子改名，同名顺延不覆盖）；③ 三页大标题上边距 28→44。
- **新增自更新「退出即装」**（`core/service/update_installer.dart` + `_UpdateInfoDialog`）：下载完成 → 「立即安装并重启」。macOS：`ditto -x -k` 解包（保留 exec 权限位、无 quarantine）→ 安装目录同级暂存 → bash 看守脚本（等旧 PID 退出 → 备份→同卷 rename 原子换包→失败回滚→`open` 重启→清 stage）；App Translocation 或安装目录不可写（如普通用户装 /Applications）自动降级手动。Windows：dart `archive` 解 zip → 找 Inno 安装器 → 中继 install.cmd（`/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /FORCECLOSEAPPLICATIONS` 因 `[Run] skipifsilent` 由批处理接力 `start` 重启）。安装前显式 `BackendService().stop()`（else 新实例自愈清理 18923）。管线实测：ditto 权限位 + 脚本换包/回滚/清理全部通过（shim 替身避免真启动）。
- **10-20 已打包交付 build 150**：`GradeMonitor-107.0.0.150-macOS.zip`（20M）+ `GradeMonitor.app` 于桌面。Info 校验：ShortVersion 107.0.0 / CFBundleVersion 150 / id com.grademonitor.app。含今日三项 UI 改动 + md 更新日志 + 应用内直接下载 + 退出即装。注意：150 之前（≤149）用户升级到 150 需手动；150 起自更新可用。
- 已知限制：Windows 批处理对路径含 `%`/`&` 等非常规字符敏感（用户名正常不受影响）；安装器未签名，个别杀软可能拦截；旧版本（≤149）用户仍需手动覆盖一次，150 起才具备自动安装能力。
- 当前工作区干净（除本快照文档）。

## 待办 / 可选迭代

- 欢迎页各步骤语言表达精修（用户未再提）。
- GitHub 首页 `logs/` 行文案。
- 正式发版时确认 tag：`git tag -f 107.0.0.149 && git push -f origin 107.0.0.149`。
