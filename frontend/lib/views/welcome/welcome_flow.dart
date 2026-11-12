import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../../providers/settings_provider.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../../widgets/toast_host.dart';

const _termsText = '''
# 免责声明

1. 本程序为个人开发项目，与任何学校、教育机构或教务系统运营方无关，**非官方软件**。
2. 本程序仅用于辅助用户查询个人成绩信息，使用过程中产生的账号异常、数据泄露、校规违反等风险，由用户自行承担。
3. 开发者不保证程序持续可用、无故障运行，不对因软件使用、系统环境变化或第三方服务异常造成的损失承担责任。
4. 开发者承诺**不收集、不上传、不存储**用户账号密码及成绩数据，相关信息仅在用户设备本地处理。
5. 用户应妥善保管账号信息，积极参与教评，并确保使用行为符合学校管理规定及相关法律法规。

# 用户使用协议

1. 用户下载、安装或使用本程序，即视为同意本协议全部内容。
2. 本程序仅限个人学习、研究及技术交流使用，**禁止用于商业用途或未经授权的传播**。
3. 用户不得利用本程序进行任何形式的服务器攻击、漏洞利用、数据爬取、恶意访问或其他影响学校计算机系统正常运行的行为。
4. 严禁通过降低查询间隔、批量账号运行、高频请求等方式增加教务系统服务器负担。
5. 用户因违规使用本程序造成的一切后果，由用户自行承担；开发者有权停止提供相关支持。
6. 如不同意上述条款，请立即停止使用并彻底删除本程序。
''';

/// 沉稳的大红（同意/不同意并排时使用，不刺眼）
const Color _disagreeRed = Color(0xFFB04A46);

/// 全窗口欢迎向导（iPhone 激活式）：占满主窗口，一页一页顺序设置。
///
/// 页面序列：0 欢迎 → 1 法律性声明 → 2 账号登录 → 3 监控设置
/// → 4 通知设置 → 5 完成设置。
/// 完成后通过 [onCompleted] 通知宿主切回主界面。
///
/// 布局约定：内容组整体水平居中，组内元素一律左对齐。
class WelcomeFlow extends ConsumerStatefulWidget {
  const WelcomeFlow({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  ConsumerState<WelcomeFlow> createState() => _WelcomeFlowState();
}

class _WelcomeFlowState extends ConsumerState<WelcomeFlow> {
  // 页面序列：0 欢迎 → 1 法律性声明 → 2 选择登录入口 → 3 账号登录
  // → 4 监控设置 → 5 通知设置 → 6 完成
  static const int _pIntro = 0;
  static const int _pAgreement = 1;
  static const int _pLoginMode = 2;
  static const int _pAccount = 3;
  static const int _pMonitor = 4;
  static const int _pNotify = 5;
  static const int _pConfirm = 6;

  int _page = _pIntro;

  // ---- 法律声明页 ----
  bool _agreed = false;
  int _countdown = 10;
  Timer? _countdownTimer;

  // ---- 登录入口选择页 ----
  List<LoginMode> _loginModes = const [];
  String _loginMode = 'jw';
  bool _modesLoading = false;
  bool _modesLoaded = false;

  // ---- 账号页 ----
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();
  bool _hidePassword = true;
  bool _verifying = false;

  // ---- 验证码 ----
  /// 当前选中的入口是否**固定**需要验证码（CAS）
  bool _modeNeedsCaptcha = false;

  /// 登录失败后后端临时要求验证码（教务系统触发风控时）
  bool _captchaRequiredByServer = false;

  /// 验证码会话 id 与图片（base64 data URI）
  String _captchaId = '';
  String _captchaImage = '';
  bool _captchaLoading = false;

  bool get _showCaptcha =>
      _modeNeedsCaptcha || _captchaRequiredByServer;

  // ---- 监控设置页 ----
  bool _autoMonitor = false;
  bool _rankMonitor = false;
  double _intervalValue = 300;
  TimeOfDay _startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 23, minute: 0);

  // ---- 通知设置页 ----
  String _notifyMode = '详细';

  // ---- 完成页 ----
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 账号/密码输入实时刷新主按钮可用状态
    _usernameCtrl.addListener(_refreshState);
    _passwordCtrl.addListener(_refreshState);
    _captchaCtrl.addListener(_refreshState);
  }

  void _refreshState() {
    if (mounted) setState(() {});
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _countdown--;
        if (_countdown <= 0) t.cancel();
      });
    });
  }

  /// 从总欢迎页进入顺序设置：此刻才开始协议阅读倒计时
  void _startFromIntro() {
    setState(() => _page = _pAgreement);
    _startCountdown();
  }

  void _back() {
    if (_page > 0) setState(() => _page--);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  String _formatTime(TimeOfDay t) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(context: context, initialTime: _startTime);
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(context: context, initialTime: _endTime);
    if (picked != null) setState(() => _endTime = picked);
  }

  // ---- 主按钮行为（随页变化） ----

  String _primaryLabel() {
    switch (_page) {
      case _pIntro:
        return '开始';
      case _pAgreement:
        // 倒计时提醒仅出现在按钮内部
        return _countdown > 0 ? '请再阅读 $_countdown 秒' : '同意';
      case _pLoginMode:
        return _modesLoading ? '正在加载...' : '下一步';
      case _pAccount:
        return _verifying ? '正在验证...' : '下一步';
      case _pMonitor:
      case _pNotify:
        return '下一步';
      default:
        return _saving ? '正在保存...' : '好';
    }
  }

  bool _primaryEnabled() {
    switch (_page) {
      case _pIntro:
        return true;
      case _pAgreement:
        return _agreed && _countdown <= 0;
      case _pLoginMode:
        return !_modesLoading && _loginMode.isNotEmpty;
      case _pAccount:
        final base = _usernameCtrl.text.trim().isNotEmpty &&
            _passwordCtrl.text.isNotEmpty &&
            !_verifying;
        // 需要验证码时，必须填满 4 位才能提交
        if (_showCaptcha) {
          return base && _captchaCtrl.text.trim().length >= 4;
        }
        return base;
      case _pMonitor:
      case _pNotify:
        return true;
      default:
        return !_saving;
    }
  }

  /// 加载登录入口列表（进入「选择登录入口」页时调用一次）
  Future<void> _loadLoginModes() async {
    if (_modesLoaded || _modesLoading) return;
    setState(() => _modesLoading = true);
    final modes = await ref.read(settingsProvider.notifier).fetchLoginModes();
    if (!mounted) return;
    // 默认选中推荐入口（教务系统直连）
    var selected = _loginMode;
    if (modes.isNotEmpty && !modes.any((m) => m.id == selected)) {
      selected = modes.firstWhere((m) => m.recommended, orElse: () => modes.first).id;
    }
    setState(() {
      _loginModes = modes;
      _loginMode = selected;
      _modesLoading = false;
      _modesLoaded = true;
      _applyModeCaptchaFlag();
    });
  }

  /// 入口切换后同步「是否需要验证码」并预取验证码
  void _applyModeCaptchaFlag() {
    final mode = _loginModes.where((m) => m.id == _loginMode);
    _modeNeedsCaptcha = mode.isNotEmpty && mode.first.needsCaptcha;
    if (_showCaptcha) {
      _refreshCaptcha();
    } else {
      _captchaId = '';
      _captchaImage = '';
      _captchaCtrl.clear();
    }
  }

  /// 选择一个登录入口
  void _selectLoginMode(String id) {
    if (id == _loginMode) return;
    setState(() {
      _loginMode = id;
      _captchaRequiredByServer = false;
      _applyModeCaptchaFlag();
    });
  }

  /// 拉取一张新验证码（切换入口 / 验证失败 / 用户点击刷新）
  Future<void> _refreshCaptcha() async {
    if (_captchaLoading) return;
    setState(() => _captchaLoading = true);
    final result =
        await ref.read(settingsProvider.notifier).fetchLoginCaptcha(_loginMode);
    if (!mounted) return;
    setState(() {
      _captchaLoading = false;
      if (result != null) {
        _captchaId = result.$1;
        _captchaImage = result.$2;
        _captchaCtrl.clear();
      } else {
        _captchaId = '';
        _captchaImage = '';
      }
    });
    if (result == null && mounted) {
      ToastHost().show('验证码获取失败，请点击图片重试');
    }
  }

  /// 账号页点击主按钮：先做真实登录验证，失败留在本页
  Future<void> _onPrimary() async {
    switch (_page) {
      case _pIntro:
        _startFromIntro();
        break;
      case _pAgreement:
        setState(() => _page = _pLoginMode);
        _loadLoginModes();
        break;
      case _pLoginMode:
        setState(() => _page = _pAccount);
        // 进入账号页时按入口决定是否立刻取一张验证码
        if (_showCaptcha && _captchaImage.isEmpty) {
          _refreshCaptcha();
        }
        break;
      case _pAccount:
        setState(() => _verifying = true);
        final result = await ref.read(settingsProvider.notifier).login(
              _usernameCtrl.text.trim(),
              _passwordCtrl.text,
              mode: _loginMode,
              captcha: _captchaCtrl.text.trim(),
              captchaId: _captchaId,
            );
        if (!mounted) return;
        setState(() => _verifying = false);
        if (!result.success) {
          ToastHost().show(result.message);
          // 后端要求验证码（教务系统风控）：动态补出输入框并取码
          if (result.captchaRequired && !_showCaptcha) {
            setState(() {
              _captchaRequiredByServer = true;
              _applyModeCaptchaFlag();
            });
          } else if (_showCaptcha) {
            // 验证码错误/过期：立刻换一张，让用户直接重输
            _refreshCaptcha();
          }
          return;
        }
        setState(() => _page = _pMonitor);
        break;
      case _pMonitor:
        setState(() => _page = _pNotify);
        break;
      case _pNotify:
        setState(() => _page = _pConfirm);
        break;
      default:
        await _finish();
    }
  }

  Future<void> _finish() async {
    setState(() => _saving = true);

    // 凭据已在账号页验证通过（login() 已把密码交给后端安全存储），
    // 这里只保存其余设置，不再重复提交密码。
    final notifier = ref.read(settingsProvider.notifier);
    final current = ref.read(settingsProvider);
    final updated = current.copyWith(
      username: _usernameCtrl.text.trim(),
      hasPassword: true,
      // 密码始终记住（曾有的"记住密码"开关已移除）
      rememberMe: true,
      loginMode: _loginMode,
      autoMonitorEnabled: _autoMonitor,
      rankMonitorEnabled: _rankMonitor,
      intervalSeconds: _intervalValue.toInt(),
      startTime: _formatTime(_startTime),
      endTime: _formatTime(_endTime),
      notifyMode: _notifyMode,
    );
    await notifier.saveSettings(updated);
    await ApiClient().completeWelcome();

    if (mounted) {
      ToastHost().show('设置已保存');
      widget.onCompleted();
    }
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    // 底色跟随系统主题：亮色纯白，深色用深底，避免深色模式下刺眼
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: isDark ? AppTheme.darkTheme : AppTheme.lightTheme,
      child: Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          // macOS 红绿灯悬浮在内容左上角，留出紧凑顶部空间
          final topInset = Platform.isMacOS ? 26.0 : 0.0;
          return Scaffold(
            backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            body: Padding(
              padding: EdgeInsets.only(top: topInset),
              child: Column(
                children: [
                  // 顶部返回区（欢迎页不显示返回）
                  SizedBox(height: 40, child: _buildBackRow(cs)),
                  // 页面内容（切换时淡入 + 轻微上移；外层 AnimatedSize
                  // 让步骤间页面高度差异平滑过渡，避免内容跳变）
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.topCenter,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, anim) {
                            final offset = Tween<Offset>(
                              begin: const Offset(0, .04),
                              end: Offset.zero,
                            ).animate(anim);
                            return FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: offset,
                                child: child,
                              ),
                            );
                          },
                          // 顶部对齐叠放：旧页淡出时新页从旧页顶部位置起始，
                          // 高度变化完全交给 AnimatedSize 平滑处理
                          layoutBuilder: (currentChild, previousChildren) {
                            return Stack(
                              alignment: Alignment.topCenter,
                              children: <Widget>[
                                ...previousChildren,
                                ?currentChild,
                              ],
                            );
                          },
                          child: KeyedSubtree(
                            key: ValueKey(_page),
                            child: _buildPage(cs),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 底部：主按钮（无圆点进度条）
                  _buildBottomBar(cs),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBackRow(ColorScheme cs) {
    if (_page == _pIntro) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: cs.onSurface.withValues(alpha: .6),
          tooltip: '返回',
          onPressed: _back,
        ),
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme cs) {
    // 法律声明页：同意 / 不同意并排
    if (_page == _pAgreement) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 52),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 176,
              height: 48,
              child: FilledButton(
                onPressed: _primaryEnabled() ? _onPrimary : null,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  _primaryLabel(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 176,
              height: 48,
              child: FilledButton(
                onPressed: () => exit(0),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  backgroundColor: _disagreeRed,
                ),
                child: const Text(
                  '不同意',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 其余页：单个居中主按钮
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 52),
      child: SizedBox(
        width: 340,
        height: 48,
        child: FilledButton(
          onPressed: _primaryEnabled() ? _onPrimary : null,
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: (_verifying || _saving)
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: cs.onPrimary,
                  ),
                )
              : Text(
                  _primaryLabel(),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimary,
                  ),
                ),
        ),
      ),
    );
  }

  // ---- 各页 ----

  Widget _buildPage(ColorScheme cs) {
    switch (_page) {
      case _pIntro:
        return _buildIntroPage(cs);
      case _pAgreement:
        return _buildAgreementPage(cs);
      case _pLoginMode:
        return _buildLoginModePage(cs);
      case _pAccount:
        return _buildAccountPage(cs);
      case _pMonitor:
        return _buildMonitorPage(cs);
      case _pNotify:
        return _buildNotifyPage(cs);
      default:
        return _buildConfirmPage(cs);
    }
  }

  /// 内容组容器：整体水平居中，组内左对齐
  Widget _contentGroup(double maxWidth, Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }

  /// 页面顶部设置图标（macOS 激活式：蓝底简形图标）+ 标题 + 副标题
  /// （组内左对齐）
  Widget _pageHeader(
    ColorScheme cs,
    IconData icon,
    String title,
    String? subtitle, {
    double inkShift = 0,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _setupIcon(cs, icon, inkShift: inkShift),
        const SizedBox(height: 16),
        Text(
          title,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            height: 1.3,
            color: cs.onSurface,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: cs.onSurface.withValues(alpha: .55),
            ),
          ),
        ],
      ],
    );
  }

  /// 设置页顶部线性图标（macOS 激活式；无底色、仅线条勾勒）。
  /// [inkShift]：Material 图标字符在字形盒内有留白，按实测墨迹左距
  /// 将图形左缘平移到与标题首字左缘精确对齐。
  Widget _setupIcon(ColorScheme cs, IconData icon, {double inkShift = 0}) {
    return Transform.translate(
      offset: Offset(-inkShift, 0),
      child: Icon(icon, size: 64, color: cs.primary),
    );
  }

  // ---- Page 0: 欢迎页 ----
  Widget _buildIntroPage(ColorScheme cs) {
    return _contentGroup(
      560,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // App 图标：圆角裁切（约为初始尺寸的 80%）
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset(
                'assets/app_icon_tb.png',
                width: 93,
                height: 93,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '欢迎使用 Grade Monitor',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                height: 1.25,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '自动查询成绩与排名更新，出分即刻提醒\n所有数据仅保存在本地，不上传云端\n轮询频率、通知模式等均可个性化调整',
              style: TextStyle(
                fontSize: 15,
                height: 2.0,
                color: cs.onSurface.withValues(alpha: .55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Page 1: 法律性声明 ----

  /// 协议正文按空行自动分段，每段独立排版，段间距 5 像素
  /// 协议正文：按 Markdown 排版（标题分级、段落、列表、加粗、链接）
  Widget _buildTermsParagraphs(ColorScheme cs) {
    return MarkdownBody(
      data: _termsText,
      softLineBreak: true,
      styleSheet: _termsMdStyle(cs),
    );
  }

  MarkdownStyleSheet _termsMdStyle(ColorScheme cs) {
    final on = cs.onSurface;
    TextStyle base({
      double size = 13,
      FontWeight weight = FontWeight.w400,
      double height = 1.62,
      double alpha = .72,
    }) => TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: on.withValues(alpha: alpha),
    );
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base(),
      pPadding: const EdgeInsets.only(bottom: 8),
      h1: base(size: 17, weight: FontWeight.w800, height: 1.4, alpha: .95)
          .copyWith(letterSpacing: -.2),
      h1Padding: const EdgeInsets.only(top: 4, bottom: 8),
      h2: base(size: 14.5, weight: FontWeight.w700, height: 1.4, alpha: .92),
      h2Padding: const EdgeInsets.only(top: 2, bottom: 6),
      h3: base(size: 13.5, weight: FontWeight.w700, height: 1.4, alpha: .9),
      strong: base(weight: FontWeight.w700, alpha: .92),
      em: base().copyWith(fontStyle: FontStyle.italic),
      a: TextStyle(
        fontSize: 13,
        color: cs.primary,
        height: 1.62,
        decoration: TextDecoration.underline,
      ),
      listBullet: base(),
      listBulletPadding: const EdgeInsets.only(right: 6),
      blockSpacing: 6,
      blockquote: base(alpha: .6),
      blockquotePadding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: cs.primary.withValues(alpha: .5), width: 3),
        ),
      ),
      code: base(size: 12).copyWith(fontFamily: 'monospace'),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: on.withValues(alpha: .12), width: 1),
        ),
      ),
    );
  }

  Widget _buildAgreementPage(ColorScheme cs) {
    return _contentGroup(
      680,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pageHeader(cs, Icons.balance_outlined, '这是一份法律性声明', null, inkShift: 5.3),
            const SizedBox(height: 16),
            // 声明正文：占满本页剩余高度
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: cs.surfaceContainerHighest.withValues(alpha: .3),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                    child: _buildTermsParagraphs(cs),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 倒计时结束后才出现勾选行
            if (_countdown <= 0)
              Row(
                children: [
                  SizedBox(
                    height: 32,
                    child: Checkbox(
                      value: _agreed,
                      onChanged: (v) => setState(() => _agreed = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => setState(() => _agreed = !_agreed),
                    child: Text(
                      '我已阅读、理解并同意上述内容',
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ---- Page 2: 选择登录入口 ----
  Widget _buildLoginModePage(ColorScheme cs) {
    return _contentGroup(
      460,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageHeader(
              cs,
              Icons.login_rounded,
              '选择登录入口',
              null,
              inkShift: 8.2,
            ),
            const SizedBox(height: 20),
            if (_modesLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              )
            else
              ..._loginModes.map((m) => _buildModeTile(cs, m)),
          ],
        ),
      ),
    );
  }

  /// 单个登录入口选项卡片
  Widget _buildModeTile(ColorScheme cs, LoginMode m) {
    final selected = _loginMode == m.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _selectLoginMode(m.id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? cs.primary.withValues(alpha: .07)
                : cs.surfaceContainerHighest.withValues(alpha: .25),

          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: .35),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          m.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        if (m.recommended) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '推荐',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        ],
                        if (m.needsCaptcha) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: cs.tertiary.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '需验证码',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: cs.tertiary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      m.description,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: .6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Page 3: 账号登录 ----
  Widget _buildAccountPage(ColorScheme cs) {
    return _contentGroup(
      400,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageHeader(
              cs,
              Icons.person_outline,
              '账户',
              null,
              inkShift: 10.4,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: '学号',
                hintText: 'ShuZhi / V RUC 账户',
                isDense: true,
                prefixIcon: Icon(Icons.badge_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: _hidePassword,
              keyboardType: TextInputType.visiblePassword,
              enableSuggestions: false,
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\x00-\x7F]')),
              ],
              decoration: InputDecoration(
                labelText: '密码',
                hintText: 'ShuZhi / V RUC 密码',
                isDense: true,
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                suffixIcon: IconButton(
                  icon: Icon(
                    _hidePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _hidePassword = !_hidePassword),
                ),
              ),
            ),
            // 密码始终保存（记住密码），无需用户勾选

            // 需要验证码的入口（或教务系统触发风控时）才显示
            if (_showCaptcha) ...[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _captchaCtrl,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      enableSuggestions: false,
                      autocorrect: false,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        hintText: '4 位数字',
                        isDense: true,
                        counterText: '',
                        prefixIcon: Icon(Icons.verified_outlined, size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildCaptchaImage(cs),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '看不清？点击图片可刷新验证码',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: .5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 验证码图片（点击刷新）；加载中显示占位
  Widget _buildCaptchaImage(ColorScheme cs) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _captchaLoading ? null : _refreshCaptcha,
      child: Container(
        width: 120,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.white,
        ),
        child: _captchaLoading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : _captchaImage.isEmpty
                ? Text(
                    '点击获取',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: .55),
                    ),
                  )
                : Image.memory(
                    base64Decode(_captchaImage.contains(',')
                        ? _captchaImage.split(',').last
                        : _captchaImage),
                    width: 112,
                    height: 40,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
      ),
    );
  }

  // ---- Page 3: 监控设置 ----
  /// 统一卡片：监控时间段 → 轮询间隔 → 监控项目，三段用分割线隔开
  Widget _buildMonitorPage(ColorScheme cs) {
    return _contentGroup(
      480,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageHeader(cs, Icons.settings_outlined, '监控设置', null, inkShift: 5.9),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  // ① 监控时间段
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '监控时间段',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  '开始',
                                  style: TextStyle(fontSize: 13),
                                ),
                                trailing: Text(
                                  _startTime.format(context),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onTap: _pickStartTime,
                                dense: true,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  '结束',
                                  style: TextStyle(fontSize: 13),
                                ),
                                trailing: Text(
                                  _endTime.format(context),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onTap: _pickEndTime,
                                dense: true,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // ② 轮询间隔
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '轮询间隔',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '每 ${_intervalValue.round()} 秒查询一次，最短 300 秒，避免对学校服务器造成过大负担',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: .45),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 40,
                          child: Slider(
                            value: _intervalValue,
                            min: 300,
                            max: 3600,
                            divisions: 66,
                            label: '${_intervalValue.round()} 秒',
                            onChanged: (v) =>
                                setState(() => _intervalValue = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ③ 监控项目
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '监控项目',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('成绩自动监控', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      '检测新出成绩或成绩变动',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _autoMonitor,
                    onChanged: (v) => setState(() => _autoMonitor = v),
                    dense: true,
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('排名自动监控', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      '检测专业排名或班级排名变动',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _rankMonitor,
                    onChanged: (v) => setState(() => _rankMonitor = v),
                    dense: true,
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Page 4: 通知设置 ----
  Widget _buildNotifyPage(ColorScheme cs) {
    return _contentGroup(
      600,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageHeader(cs, Icons.notifications_outlined, '通知设置', null, inkShift: 10.4),
            const SizedBox(height: 16),
            _notifyCard(
              cs,
              value: '详细',
              title: '完整模式',
              desc: '在通知中显示课程名、绩点与排名变化，信息更全面。',
              icon: Icons.notifications_active_outlined,
            ),
            const SizedBox(height: 12),
            _notifyCard(
              cs,
              value: '简洁',
              title: '简洁模式',
              desc: '仅提示「您有成绩或排名更新」，保护隐私。',
              icon: Icons.notifications_none_outlined,
            ),
          ],
        ),
      ),
    );
  }

  /// 通知模式选择卡片：介绍 + 单选
  Widget _notifyCard(
    ColorScheme cs, {
    required String value,
    required String title,
    required String desc,
    required IconData icon,
  }) {
    final selected = _notifyMode == value;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _notifyMode = value),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? cs.primary.withValues(alpha: .1)
                : cs.surfaceContainerHighest.withValues(alpha: .3),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color:
                    selected ? cs.primary : cs.onSurface.withValues(alpha: .3),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 18, color: cs.primary),
                        const SizedBox(width: 6),
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: .55),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Page 5: 完成设置 ----
  Widget _buildConfirmPage(ColorScheme cs) {
    final monitorDesc = [];
    if (_autoMonitor) monitorDesc.add('成绩监控');
    if (_rankMonitor) monitorDesc.add('排名监控');
    final monitorText = monitorDesc.isEmpty ? '未开启' : monitorDesc.join(' + ');
    final timeText =
        '${_startTime.format(context)} - ${_endTime.format(context)}';

    return _contentGroup(
      480,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageHeader(cs, Icons.task_alt_outlined, '所有配置已完成', null, inkShift: 5.3),
            const SizedBox(height: 16),
            // 设置摘要卡片（不显示密码，新增轮询间隔）
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _confirmRow(cs, '学号', _usernameCtrl.text.trim()),
                  _confirmRow(cs, '监控项目', monitorText),
                  _confirmRow(cs, '监控时间', timeText),
                  _confirmRow(cs, '轮询间隔', '${_intervalValue.round()} 秒'),
                  _confirmRow(
                    cs,
                    '通知模式',
                    _notifyMode == '详细' ? '完整模式' : '简洁模式',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.primary.withValues(alpha: .2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '完成配置后，程序将自动开始在后台监测成绩与排名变动。'
                      '所有数据仅保存在本地，请放心使用。',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: .7),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _confirmRow(ColorScheme cs, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: .5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '未设置' : value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.35,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
