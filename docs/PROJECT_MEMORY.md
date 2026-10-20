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
- **「方案计算」页骨架**（build 150 打包之后新增，未打包）：位于成绩单与设置之间（导航枚举第 3 位，图标 calculate_rounded），`views/scheme/scheme_page.dart`；大标题「方案计算」+小标题「根据您的推免方案计算您的 811 / 82 结果」，主体留空待后续迭代。
- **「方案计算」页第一轮内容**：红色警示横条（结果仅作参考，需自行核对培养方案/院系方案）+ 蓝色提示横条（免试推荐适用的学业综合成绩计算范围全文，文案用户逐字给定，勿改动字词）+ GlassCard 单选卡「811 方案」「82 方案」（样式 RadioGroup<String>，值 '811'/'82'，未选默认 null；Radio.groupValue/onChanged 旧参数已弃用一律走 RadioGroup）。计算功能主体后续迭代。
- **新增自更新「退出即装」**（`core/service/update_installer.dart` + `_UpdateInfoDialog`）：下载完成 → 「立即安装并重启」。macOS：`ditto -x -k` 解包（保留 exec 权限位、无 quarantine）→ 安装目录同级暂存 → bash 看守脚本（等旧 PID 退出 → 备份→同卷 rename 原子换包→失败回滚→`open` 重启→清 stage）；App Translocation 或安装目录不可写（如普通用户装 /Applications）自动降级手动。Windows：dart `archive` 解 zip → 找 Inno 安装器 → 中继 install.cmd（`/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /FORCECLOSEAPPLICATIONS` 因 `[Run] skipifsilent` 由批处理接力 `start` 重启）。安装前显式 `BackendService().stop()`（else 新实例自愈清理 18923）。管线实测：ditto 权限位 + 脚本换包/回滚/清理全部通过（shim 替身避免真启动）。
- **方案计算功能已完成**（build 151）：
  - 核心绩口径细化：**学分加权**＝Σjd÷Σxf（jd 为单科总绩点＝单科绩点×学分，与成绩单 avgGpa=jd/xf 同源）；有效参与＝白名单 ∩（jd、xf 均可解析且 xf>0）。
  - 新文件 `views/scheme/scheme_core.dart`：白名单（20项）+ normalize（全半角/空白归一，仅此两类）+ analyze 返回同一课程集合——成绩单筛选与统计共用，保证范围一致。
  - `GradeCourse` 模型补了 `kclbname` 字段（此前被 fromJson 丢掉）。
  - 成绩单页：工具栏新增「范围：全部课程/核心绩课程」下拉 + 「核心绩 x.xx（N 门 · 学分加权）」徽章（含 Tooltip 口径说明）；空态文案覆盖核心绩情形。
  - 方案计算页：单选 811/82（各带算式小字）；核心绩卡（自动预填 2 位小数，双击自定义，恢复自动按钮，自定义后不再被覆盖）；学术/综合 0–4.0 输入卡（综合仅 811 可用）+ 无效输入红字；结果卡实时算式与总分（40px），无方案时显示 '--'。
  - 真实数据校验：31 门 / ∑jd=233.40 / ∑xf=64.0 / 核心绩=3.6469（简单平均 3.6613 对比，证伪）。
- **10-20 已打包交付 build 151**：`GradeMonitor-107.0.0.151-macOS.zip`（20M，含方案计算页全部功能）+ Desktop `GradeMonitor.app`。build 150 zip 保留在桌面未删。
- 已知限制：Windows 批处理对路径含 `%`/`&` 等非常规字符敏感（用户名正常不受影响）；安装器未签名，个别杀软可能拦截；旧版本（≤149）用户仍需手动覆盖一次，150 起才具备自动安装能力。
- 当前工作区干净（除本快照文档）。

## 方案计算 · 免试推荐计算规则（用户口述，2026-10-20，**勿改动，待实现**）

- **方案命名拆解**：
  - `811` = 核心绩(8成) + **学术科研能力**(1成) + **综合能力**(1成)
  - `82` = 核心绩(8成) + **学术科研能力**(2成)
- **算式**：
  - 811：`核心绩×80% + 学术×10% + 综合×10%`
  - 82：`核心绩×80% + 学术×20%`
- **输入来源**：
  - **核心绩**：App 自动计算（来自成绩单数据；具体口径待定：是否学分加权、哪些学期、绩点换算——实现时再向用户确认，蓝条中的"计算范围"是权威依据）
  - **学术科研能力**：文本框让用户自填，**最高 4.0**
  - **综合能力**：文本框让用户自填，**最高 4.0**
- 两个文本框同为手动输入数值，需做 0–4.0 范围校验。

## 方案计算 · 核心绩课程白名单（用户给定，2026-10-20，**勿改勿扩**）

- 数据源：`local_grades.json`（用户口述为 local_grade.json；实际文件名带复数 s）
- 判定字段：每门课程的 **`kclbname`**（payload 里另有 `szkclbname`，本办法只认 `kclbname`）
- **匹配规则**：白名单**全字匹配**；预处理仅允许两类归一（全角↔半角符号、去除空格）——除此之外**禁止**模糊/子串/关键词匹配，**禁止擅自扩大核心绩课程范围**
- 命中课程的核心绩 = **学分加权**（Σjd ÷ Σxf；jd 为单科总绩点＝单科绩点×学分，与成绩单 avgGpa=jd/xf 同源）；有效参与 = 白名单 ∩（jd、xf 均可解析且 xf>0）
- **2026-10-20 用户拍板：'思想政治理论课' 类别整类排除**（其中的思政实践课为 P/通过制绩点 1.0，官方不计入；核对后 30 门 / 3.73 与教务系统完全一致）
- 白名单（19 项，逐字原样）：

| # | kclbname 白名单值 |
|---|---|
| 1 | 思政课 |
| 2 | 大学外语 |
| 3 | 大学外语（拓展类课程） |
| 4 | 公共外语 |
| 5 | 公共外语课 |
| 6 | 公共外语（拓展类课程） |
| 7 | 公共计算机 |
| 8 | 公共数学 |
| 9 | 公共数学课 |
| 10 | 部类共同 |
| 11 | 部类共同课 |
| 12 | 部类基础 |
| 13 | 部类基础课 |
| 14 | 专业基础课 |
| 15 | 学科基础 |
| 16 | 专业核心课 |
| 17 | 专业必修 |
| 18 | 人工智能与数据技术平台课 |
| 19 | 数据与信息技术平台课 |

## 待办 / 可选迭代

- 欢迎页各步骤语言表达精修（用户未再提）。
- GitHub 首页 `logs/` 行文案。
- 正式发版时确认 tag：`git tag -f 107.0.0.151 && git push -f origin 107.0.0.151`。
- **本轮（10-20 第二轮）改动已实现、未打包**：用户发文后触发，如需交付照例 build 号 +1（现为 152）。

## 2026-10-20 第二轮：白名单收敛 + 提示规范 + 精度开关

- **核心绩口径修正（用户拍板）**：'思想政治理论课' **整类排除**（思政实践课 P/通过制绩点 1.0 不得计入）→ 白名单 19 项，**30 门 / 学分加权 3.73，与官方教务系统完全一致**。镜像验证：Σjd=231.40、Σxf=62.0、3.7323。
- **提示横条统一规范**：新建共享组件 `widgets/note_banner.dart`（NoteBanner.warning / NoteBanner.info）——图标、标题、正文**各自换行**，**标题加粗**；红条=三角感叹号 +「注意」，蓝条=info_outline +「提示」。
  - 方案计算页红/蓝条已切到 NoteBanner；成绩单页副标题下新增红色「注意」条（用户逐字文案，勿改字词）：培养方案持续更新/字段不完全对应可能导致误差仅供参考，以学校学院正式文件与教务系统为准并自行核验。
- **方案计算页文案**：副标题 →"根据您的实际情况计算您的 811/82 结果"（逐字）；输入框 hint "如 3.75" → "如 3.70"。
- **计算结果 5 位小数开关**：结果卡标题行右侧「5 位小数」Switch（默认关=2 位；开=5 位不足补 0，toStringAsFixed 自动补零）。开关同时影响：结果值、算式分解各行、核心绩自动显示值。**自动模式下计算用全精度核心绩**（非页面四舍五入值）；双击自定义后按用户输入解析。核心绩框 maxLength 4→8（容纳 '3.73226'）。
- **首页四板块微调（×90%/×80%）**：_statTile icon 44→**39.6**，灰色 label 18.75→**15.0**（数值 68 不动）。
