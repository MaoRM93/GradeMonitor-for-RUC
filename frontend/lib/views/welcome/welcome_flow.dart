import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/service/feature_gate_service.dart';
import '../../core/service/ui_prefs_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../../widgets/feature_gate.dart';
import '../../widgets/expressive_switch.dart';
import '../../providers/settings_provider.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../../widgets/toast_host.dart';
import '../../widgets/window_controls.dart';

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

enum _WelcomePageMotion { idle, exiting, entering }

/// 沉稳的大红（同意/不同意并排时使用，不刺眼）
const Color _disagreeRed = Color(0xFFB04A46);

/// 全窗口欢迎向导（iPhone 激活式）：占满主窗口，一页一页顺序设置。
///
/// 页面序列：0 欢迎 → 1 法律性声明 → 2 账号登录 → 3 监控设置
/// → 4 通知设置 → 5 选择主题 → 6 完成设置。
/// 完成后通过 [onCompleted] 通知宿主切回主界面。
///
/// 布局约定：内容组整体水平居中，组内元素一律左对齐。
class WelcomeFlow extends ConsumerStatefulWidget {
  const WelcomeFlow({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  ConsumerState<WelcomeFlow> createState() => _WelcomeFlowState();
}

class _ThemeMeta {
  const _ThemeMeta(this.title, this.color);

  final String title;
  final Color color;
}

class _WelcomeFlowState extends ConsumerState<WelcomeFlow>
    // 本页同时驱动环境光与页面切换两个 AnimationController，
    // SingleTickerProviderStateMixin 只允许一个 ticker，会直接断言失败。
    with TickerProviderStateMixin {
  // 页面序列：0 欢迎 → 1 法律性声明 → 2 选择登录入口 → 3 账号登录
  // → 4 监控设置 → 5 通知设置 → 6 主题选择 → 7 完成
  static const int _pIntro = 0;
  static const int _pAgreement = 1;
  static const int _pLoginMode = 2;
  static const int _pAccount = 3;
  static const int _pMonitor = 4;
  static const int _pNotify = 5;
  static const int _pTheme = 6;
  static const int _pConfirm = 7;

  /// 引导页「卡片级」容器统一圆角：与主按钮、全局输入框的 12 对齐。
  /// 4px 只用于「推荐 / 需验证码」小标签，不参与此常量。

  /// 主题输入框（contentPadding 16/14 + 浮动标签）实测渲染高度 55；
  /// 验证码图片块取同值，保证同一行内视觉高度一致。
  static const double _captchaTileHeight = 55;

  int _page = _pIntro;
  int _transitionDirection = 1;
  _WelcomePageMotion _pageMotion = _WelcomePageMotion.idle;
  bool _pageTransitioning = false;
  int? _queuedPage;

  // ---- 法律声明页 ----
  bool _agreed = false;
  int _countdown = 10;
  Timer? _countdownTimer;

  // ---- 登录入口选择页 ----
  List<LoginMode> _loginModes = const [];
  String _loginMode = 'cas';
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

  bool get _showCaptcha => _modeNeedsCaptcha || _captchaRequiredByServer;

  // ---- 监控设置页 ----
  bool _autoMonitor = false;
  bool _rankMonitor = false;
  double _intervalValue = 300;
  TimeOfDay _startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 23, minute: 0);

  // ---- 通知设置页 ----
  String _notifyMode = '详细';

  // ---- 主题选择页 ----
  ThemePreset _selectedTheme = AppTheme.defaultPreset;
  ThemeMode _selectedThemeMode = ThemeMode.system;

  // ---- 完成页 ----
  bool _saving = false;
  late final AnimationController _ambientController;
  late final AnimationController _pageMotionController;

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    )..repeat(reverse: true);
    _pageMotionController = AnimationController(vsync: this);
    // 账号/密码输入实时刷新主按钮可用状态
    _usernameCtrl.addListener(_refreshState);
    _passwordCtrl.addListener(_refreshState);
    _captchaCtrl.addListener(_refreshState);

    UiPrefsService.ensureLoaded().then((_) {
      if (!mounted) return;
      final storedPreset = AppTheme.presetForId(
        UiPrefsService.readPref(UiPrefsService.prefThemePreset),
      );
      final storedMode = UiPrefsService.readPref(UiPrefsService.prefThemeMode);
      setState(() {
        _selectedTheme = storedPreset;
        _selectedThemeMode = switch (storedMode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      });
    });

    // Flag-1040~1045 决定引导流程里哪些步骤仍然存在。
    // 开关拉取是异步的：先按"全开"渲染，回来后若当前步骤已被下线再跳到下一步。
    FeatureGateService.instance.ensureLoaded().then((_) {
      if (!mounted || _stepEnabled(_page)) return;
      final next = _nextEnabled(_page);
      if (next != null) _goto(next);
    });
  }

  // ---- 功能组开关（Flag-1040 ~ Flag-1045）----

  /// 该引导步骤是否被放行。未配置开关时视为开启，保证流程完整。
  bool _stepEnabled(int page) {
    switch (page) {
      case _pAgreement:
        return featureEnabled(FeatureGateService.flag1040Agreement);
      case _pLoginMode:
        return featureEnabled(FeatureGateService.flag1041LoginMode);
      case _pAccount:
        return featureEnabled(FeatureGateService.flag1042Account);
      case _pMonitor:
        return featureEnabled(FeatureGateService.flag1043MonitorStep);
      case _pNotify:
        return featureEnabled(FeatureGateService.flag1044NotifyStep);
      case _pTheme:
        return true;
      case _pConfirm:
        return featureEnabled(FeatureGateService.flag1045Confirm);
      default:
        return true;
    }
  }

  /// 从 [from] 之后第一个启用的步骤；已到末尾返回 null（表示可以直接收尾）。
  int? _nextEnabled(int from) {
    for (var p = from + 1; p <= _pConfirm; p++) {
      if (_stepEnabled(p)) return p;
    }
    return null;
  }

  /// 前进到下一个启用步骤；没有下一步说明流程已到尾，直接收尾保存。
  void _advance() {
    final next = _nextEnabled(_page);
    if (next == null) {
      _finish();
      return;
    }
    _goto(next);
  }

  /// 从 [from] 之前第一个启用的步骤。
  int? _prevEnabled(int from) {
    for (var p = from - 1; p >= _pIntro; p--) {
      if (_stepEnabled(p)) return p;
    }
    return null;
  }

  /// 切到目标步骤，并补上该步骤的"进入副作用"（登录入口列表、验证码）。
  Future<void> _goto(int page) async {
    if (!mounted || page == _page) return;
    if (_pageTransitioning) {
      _queuedPage = page;
      return;
    }
    _pageTransitioning = true;
    setState(() {
      _transitionDirection = page >= _page ? 1 : -1;
      _pageMotion = _WelcomePageMotion.exiting;
    });

    // 串行交接：旧页完全离开后才创建并推进新页，避免两个复杂页面
    // 同时布局/绘制造成卡顿与“下一页抢先出现”的视觉问题。
    await _pageMotionController.animateTo(
      1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInCubic,
    );
    if (!mounted) return;

    _pageMotionController.value = 0;
    setState(() {
      _page = page;
      _pageMotion = _WelcomePageMotion.entering;
    });
    if (page == _pLoginMode) _loadLoginModes();
    if (page == _pAccount && _showCaptcha && _captchaImage.isEmpty) {
      _refreshCaptcha();
    }

    await _pageMotionController.animateTo(
      1,
      duration: const Duration(milliseconds: 460),
      curve: const Cubic(.16, .88, .24, 1),
    );
    if (!mounted) return;
    setState(() => _pageMotion = _WelcomePageMotion.idle);
    _pageTransitioning = false;
    final queued = _queuedPage;
    _queuedPage = null;
    if (queued != null && queued != _page) _goto(queued);
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
    _goto(_nextEnabled(_pIntro) ?? _pAgreement);
    _startCountdown();
  }

  void _back() {
    final prev = _prevEnabled(_page);
    if (prev != null) _goto(prev);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _ambientController.dispose();
    _pageMotionController.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  String _formatTime(TimeOfDay t) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );
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
      case _pTheme:
        return '下一步';
      default:
        return _saving ? '正在保存...' : '好';
    }
  }

  bool _primaryEnabled() {
    if (_pageTransitioning) return false;
    switch (_page) {
      case _pIntro:
        return true;
      case _pAgreement:
        return _agreed && _countdown <= 0;
      case _pLoginMode:
        return !_modesLoading && _loginMode.isNotEmpty;
      case _pAccount:
        final base =
            _usernameCtrl.text.trim().isNotEmpty &&
            _passwordCtrl.text.isNotEmpty &&
            !_verifying;
        // 验证码字符数由教务系统决定，可能是字母、数字或二者混合；前端只
        // 约束为非空，避免新版验证码因位数变化而无法提交。
        if (_showCaptcha) {
          return base && _captchaCtrl.text.trim().isNotEmpty;
        }
        return base;
      case _pMonitor:
      case _pNotify:
      case _pTheme:
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
      selected = modes
          .firstWhere((m) => m.recommended, orElse: () => modes.first)
          .id;
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
    final result = await ref
        .read(settingsProvider.notifier)
        .fetchLoginCaptcha(_loginMode);
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
      case _pLoginMode:
        // 下一步：跳过被功能组下线的步骤，并补齐目标页的进入副作用
        _advance();
        break;
      case _pAccount:
        setState(() => _verifying = true);
        final result = await ref
            .read(settingsProvider.notifier)
            .login(
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
        _advance();
        break;
      case _pMonitor:
      case _pNotify:
      case _pTheme:
        _advance();
        break;
      default:
        await _finish();
    }
  }

  Future<void> _finish() async {
    setState(() => _saving = true);

    await ThemeController.instance.setPreset(_selectedTheme);
    await ThemeController.instance.setMode(_selectedThemeMode);

    // 凭据已在账号页验证通过（login() 已把密码交给后端安全存储），
    // 这里只保存其余设置，不再重复提交密码。
    final notifier = ref.read(settingsProvider.notifier);
    final current = ref.read(settingsProvider);
    final updated = current.copyWith(
      username: _usernameCtrl.text.trim(),
      // Flag-1042 被关闭时账号页会被跳过，不能伪造“已有密码”状态。
      hasPassword: _usernameCtrl.text.trim().isNotEmpty,
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
    final systemBrightness = MediaQuery.platformBrightnessOf(context);
    final brightness = switch (_selectedThemeMode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      _ => systemBrightness,
    };
    final isDark = brightness == Brightness.dark;
    return Theme(
      data: AppTheme.themeFor(_selectedTheme, brightness),
      child: Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          // macOS 红绿灯悬浮在内容左上角，留出紧凑顶部空间；
          // Windows 无系统标题栏，顶部由 WindowDragStrip 接管拖拽，
          // 这里让出同样高度，避免返回按钮落在拖拽带上。
          final topInset = Platform.isMacOS
              ? 26.0
              : (usesInWindowControls ? kWindowDragStripHeight : 0.0);
          return Scaffold(
            backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            body: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: IgnorePointer(
                      child: _WelcomeAtmosphere(
                        animation: _ambientController,
                        color: cs.primary,
                        isDark: isDark,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: Column(
                    children: [
                      // 顶部返回区（欢迎页不显示返回）
                      SizedBox(height: 40, child: _buildBackRow(cs)),
                      // 页面内容按流程方向横向交接；背景动画隔离在独立重绘层中，
                      // 避免内容输入或倒计时触发整页反复绘制。
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          // Align 会向子项传递 loose 约束。若 AnimatedSize 按
                          // 子项的最小固有宽度收缩，_contentGroup 的 Center 会
                          // 变成 0 宽，导致首个欢迎页只剩溢出的图标和背景。
                          // SizedBox 保持动画区占满可用宽度；与 Windows 顶栏、
                          // 拖拽带和三键浮层无关。
                          child: SizedBox(
                            width: double.infinity,
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 440),
                              curve: Curves.easeInOutCubic,
                              alignment: Alignment.topCenter,
                              child: AnimatedBuilder(
                                animation: _pageMotionController,
                                child: RepaintBoundary(
                                  child: KeyedSubtree(
                                    key: ValueKey(_page),
                                    child: _buildPage(cs),
                                  ),
                                ),
                                builder: (context, child) {
                                  final t = _pageMotionController.value;
                                  final progress = Curves.easeOutCubic
                                      .transform(t);
                                  final direction = _transitionDirection
                                      .toDouble();
                                  final offset = switch (_pageMotion) {
                                    _WelcomePageMotion.exiting => Offset(
                                      -.10 * direction * progress,
                                      0,
                                    ),
                                    _WelcomePageMotion.entering => Offset(
                                      .10 * direction * (1 - progress),
                                      0,
                                    ),
                                    _WelcomePageMotion.idle => Offset.zero,
                                  };
                                  final opacity = switch (_pageMotion) {
                                    _WelcomePageMotion.exiting => 1 - progress,
                                    _WelcomePageMotion.entering => progress,
                                    _WelcomePageMotion.idle => 1.0,
                                  };
                                  return Opacity(
                                    opacity: opacity,
                                    child: FractionalTranslation(
                                      translation: offset,
                                      child: child,
                                    ),
                                  );
                                },
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
              ],
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
          style: IconButton.styleFrom(
            backgroundColor: AppShape.groupFill(cs),
            shape: const StadiumBorder(),
          ),
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
                  shape: const StadiumBorder(),
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
                  shape: const StadiumBorder(),
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
            shape: const StadiumBorder(),
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
      case _pTheme:
        return _buildThemePage(cs);
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
            fontFamily: AppTheme.serifFontFamily,
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
              borderRadius: AppShape.outer,
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
                fontFamily: AppTheme.serifFontFamily,
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
      h1: base(
        size: 17,
        weight: FontWeight.w800,
        height: 1.4,
        alpha: .95,
      ).copyWith(letterSpacing: -.2),
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
            _pageHeader(
              cs,
              Icons.balance_outlined,
              '这是一份法律性声明',
              null,
              inkShift: 5.3,
            ),
            const SizedBox(height: 16),
            // 声明正文：占满本页剩余高度
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: AppShape.outer,
                  color: AppShape.groupFill(cs),
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
            _pageHeader(cs, Icons.login_rounded, '选择登录入口', null, inkShift: 8.2),
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
              // 一组纵向选项：只有首项的上两角、末项的下两角是大圆角，
              // 中间项一律小圆角，整组视觉上拼成一个圆角矩形。
              ...List.generate(_loginModes.length, (i) {
                return _buildModeTile(
                  cs,
                  _loginModes[i],
                  first: i == 0,
                  last: i == _loginModes.length - 1,
                );
              }),
          ],
        ),
      ),
    );
  }

  /// 单个登录入口选项卡片
  ///
  /// [first] / [last] 决定它是整组的第一项还是最后一项：只有首项的上两角
  /// 与末项的下两角用大圆角，其余角（含中间项四角）一律小圆角。
  Widget _buildModeTile(
    ColorScheme cs,
    LoginMode m, {
    required bool first,
    required bool last,
  }) {
    final selected = _loginMode == m.id;
    final radius = AppShape.segmented(first: first, last: last);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : AppShape.gapInner),
      child: InkWell(
        borderRadius: radius,
        onTap: () => _selectLoginMode(m.id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: radius,
            color: selected
                ? cs.primary.withValues(alpha: .07)
                : AppShape.groupFill(cs),
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
                        if (m.id == 'jw') ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: cs.secondary.withValues(alpha: .12),
                              borderRadius: AppShape.inner,
                            ),
                            child: Text(
                              '经典',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: cs.secondary,
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
                              borderRadius: AppShape.inner,
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
            _pageHeader(cs, Icons.person_outline, '账户', null, inkShift: 10.4),
            const SizedBox(height: 24),
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: '学号',
                hintText: 'ShuZhi / V RUC 账户',
                prefixIcon: Icon(Icons.badge_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: _hidePassword,
              style: _hidePassword
                  ? const TextStyle(letterSpacing: -1.2)
                  : null,
              keyboardType: TextInputType.visiblePassword,
              enableSuggestions: false,
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\x00-\x7F]')),
              ],
              decoration: InputDecoration(
                labelText: '密码',
                hintText: 'ShuZhi / V RUC 密码',
                labelStyle: const TextStyle(letterSpacing: 0),
                floatingLabelStyle: const TextStyle(letterSpacing: 0),
                hintStyle: const TextStyle(letterSpacing: 0),
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                suffixIcon: IconButton(
                  icon: Icon(
                    _hidePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _hidePassword = !_hidePassword),
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
                      keyboardType: TextInputType.visiblePassword,
                      enableSuggestions: false,
                      autocorrect: false,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Za-z0-9]'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        hintText: '请输入验证码',
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
      borderRadius: AppShape.outer,
      onTap: _captchaLoading ? null : _refreshCaptcha,
      child: Container(
        width: 120,
        height: _captchaTileHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: AppShape.outer,
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
                base64Decode(
                  _captchaImage.contains(',')
                      ? _captchaImage.split(',').last
                      : _captchaImage,
                ),
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
            _pageHeader(
              cs,
              Icons.settings_outlined,
              '监控设置',
              null,
              inkShift: 5.9,
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: AppShape.groupFill(cs),
                borderRadius: AppShape.outer,
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
                  _welcomeMonitorToggle(
                    cs,
                    title: '成绩自动监控',
                    subtitle: '检测新出成绩或成绩变动',
                    value: _autoMonitor,
                    onChanged: (v) => setState(() => _autoMonitor = v),
                  ),
                  _welcomeMonitorToggle(
                    cs,
                    title: '排名自动监控',
                    subtitle: '检测专业排名或班级排名变动',
                    value: _rankMonitor,
                    onChanged: (v) => setState(() => _rankMonitor = v),
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

  Widget _welcomeMonitorToggle(
    ColorScheme cs, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: AppShape.inner,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: .58),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            ExpressiveSwitch(value: value, onChanged: onChanged, height: 30),
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
            _pageHeader(
              cs,
              Icons.notifications_outlined,
              '通知设置',
              null,
              inkShift: 10.4,
            ),
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
      borderRadius: AppShape.outer,
      child: InkWell(
        borderRadius: AppShape.outer,
        onTap: () => setState(() => _notifyMode = value),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: AppShape.outer,
            color: selected
                ? cs.primary.withValues(alpha: .1)
                : AppShape.groupFill(cs),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: .3),
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

  // ---- Page 6: 主题选择 ----
  Widget _buildThemePage(ColorScheme cs) {
    final presets = ThemePreset.values;
    return _contentGroup(
      680,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageHeader(
              cs,
              Icons.palette_outlined,
              '选择一套主题吧',
              null,
              inkShift: 7.4,
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 10.0;
                final columns = constraints.maxWidth >= 560 ? 3 : 2;
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final preset in presets)
                      SizedBox(
                        width: width,
                        child: _themePresetCard(cs, preset),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Text(
              '显示模式',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _themeModeChip(cs, ThemeMode.system, '跟随系统'),
                _themeModeChip(cs, ThemeMode.light, '浅色'),
                _themeModeChip(cs, ThemeMode.dark, '深色'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _themePresetCard(ColorScheme cs, ThemePreset preset) {
    final selected = preset == _selectedTheme;
    final meta = _themeMeta(preset);
    return Material(
      color: Colors.transparent,
      borderRadius: AppShape.outer,
      child: InkWell(
        borderRadius: AppShape.outer,
        onTap: () => setState(() => _selectedTheme = preset),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? meta.color.withValues(alpha: .18)
                : AppShape.groupFill(cs),
            borderRadius: AppShape.outer,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: selected ? 56 : 42,
                    height: 30,
                    decoration: BoxDecoration(
                      color: meta.color,
                      borderRadius: AppShape.inner,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                meta.title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _themeModeChip(ColorScheme cs, ThemeMode mode, String label) {
    final selected = _selectedThemeMode == mode;
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => setState(() => _selectedThemeMode = mode),
      label: Text(label),
      labelStyle: TextStyle(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? cs.primary : cs.onSurface,
      ),
      side: BorderSide.none,
      backgroundColor: AppShape.groupFill(cs),
      selectedColor: cs.primary.withValues(alpha: .16),
    );
  }

  _ThemeMeta _themeMeta(ThemePreset preset) {
    return switch (preset) {
      ThemePreset.classicBlue => const _ThemeMeta('经典蓝', Color(0xFF1565C0)),
      ThemePreset.rucRed => const _ThemeMeta('人大红', Color(0xFFAE0B2A)),
      ThemePreset.glacierBlue => const _ThemeMeta('冰川蓝', Color(0xFF34618A)),
      ThemePreset.sageGreen => const _ThemeMeta('鼠尾草绿', Color(0xFF486548)),
      ThemePreset.snowWhite => const _ThemeMeta('典雅灰', Color(0xFF62717D)),
      ThemePreset.obsidianGold => const _ThemeMeta('古檀褐', Color(0xFF78602F)),
    };
  }

  // ---- Page 7: 完成设置 ----
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
            _pageHeader(
              cs,
              Icons.task_alt_outlined,
              '所有配置已完成',
              null,
              inkShift: 5.3,
            ),
            const SizedBox(height: 16),
            // 设置摘要卡片（不显示密码，新增轮询间隔）
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppShape.groupFill(cs),
                borderRadius: AppShape.outer,
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
                  _confirmRow(cs, '主题', _themeMeta(_selectedTheme).title),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: .08),
                borderRadius: AppShape.outer,
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

class _WelcomeAtmosphere extends StatelessWidget {
  const _WelcomeAtmosphere({
    required this.animation,
    required this.color,
    required this.isDark,
  });

  final Animation<double> animation;
  final Color color;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final travel = Curves.easeInOutSine.transform(animation.value);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: -170 + travel * 38,
              right: -120 - travel * 26,
              child: _orb(color.withValues(alpha: isDark ? .12 : .075), 360),
            ),
            Positioned(
              bottom: -210 - travel * 30,
              left: -150 + travel * 42,
              child: _orb(color.withValues(alpha: isDark ? .09 : .055), 410),
            ),
            Positioned(
              top: 118 + travel * 24,
              left: 74 - travel * 16,
              child: _orb(color.withValues(alpha: isDark ? .06 : .04), 96),
            ),
          ],
        );
      },
    );
  }

  Widget _orb(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
