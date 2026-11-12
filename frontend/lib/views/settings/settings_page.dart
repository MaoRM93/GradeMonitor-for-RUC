import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/service/tray_service.dart';
import '../../core/service/session_service.dart';
import '../../core/logger/app_logger.dart';
import '../../core/service/update_installer.dart';
import '../../core/service/update_service.dart';
import '../../core/service/update_verifier.dart';
import '../../providers/settings_provider.dart';
import '../../providers/monitor_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/note_banner.dart';
import '../../widgets/toast_host.dart';

/// 系统设置页面（所有开关即时生效）
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _log = AppLogger('settings_ui');

  // 表单控制器
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _hidePassword = true;
  bool _rememberMe = false;
  bool _isLoggingIn = false;

  /// 后端是否已保存密码（仅用于提示文案，前端不再持有明文）
  bool _hasSavedPassword = false;

  /// 是否处于已登录状态（学号 + 已保存凭据）。
  /// 已登录时账号区只展示学号与「退出登录」，不再展示密码输入框；
  /// 退出后回退成登录表单，供用户重新登录。
  bool _loggedIn = false;
  bool _isLoggingOut = false;

  // 登录入口与验证码（与欢迎向导一致）
  List<LoginMode> _loginModes = const [];
  String _loginMode = 'jw';
  bool _modeNeedsCaptcha = false;
  bool _captchaRequiredByServer = false;
  final _captchaCtrl = TextEditingController();
  String _captchaId = '';
  String _captchaImage = '';
  bool _captchaLoading = false;

  bool get _showCaptcha => _modeNeedsCaptcha || _captchaRequiredByServer;

  // 监控设置
  bool _autoMonitor = false;
  bool _rankMonitor = false;
  double _intervalValue = 300;
  bool _safeMode = true;
  TimeOfDay _startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 23, minute: 0);

  // 通知设置
  String _notifyMode = '详细';
  bool _autoStart = false;
  bool _showMenubarIcon = true;
  bool _hideUnknownCourses = true;
  bool _prevShowMenubarIcon = true;
  bool _loaded = false;

  // 检查更新状态
  _UpdateStatus _updateStatus = _UpdateStatus.idle;
  String _updateMessage = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadSettings);
  }

  Future<void> _loadSettings() async {
    await ref.read(settingsProvider.notifier).fetchSettings();
    final s = ref.read(settingsProvider);
    _usernameCtrl.text = s.username;
    // 后端不再回传密码（安全存储），输入框留空；
    // 已保存密码时用 hint 提示"留空则保持原密码"。
    _passwordCtrl.text = '';
    _hasSavedPassword = s.hasPassword;
    _rememberMe = s.rememberMe;
    _hidePassword = true;
    // 已登录 = 有学号且后端保存着密码（退出登录后两者都会被清空）
    _loggedIn = s.username.isNotEmpty && s.hasPassword;
    _autoMonitor = s.autoMonitorEnabled;
    _rankMonitor = s.rankMonitorEnabled;
    _safeMode = s.randomIntervalEnabled;
    // 设置里可能存有超出滑块范围（300–3600）的值（如测试期间写入的 10 秒），
    // Slider 要求 value 处于 [min, max]，加载时收敛到合法区间
    _intervalValue = s.intervalSeconds.toDouble().clamp(300.0, 3600.0);
    final start = _parseTime(s.startTime);
    final end = _parseTime(s.endTime);
    _startTime = start;
    _endTime = end;
    _notifyMode = s.notifyMode;
    _autoStart = s.autoStart;
    _showMenubarIcon = s.showMenubarIcon;
    _hideUnknownCourses = s.hideUnknownCourses;
    _prevShowMenubarIcon = s.showMenubarIcon;
    _loginMode = s.loginMode;
    _loaded = true;
    setState(() {});

    // 登录入口列表与验证码：失败不阻塞设置页
    _loadLoginModes();

    if (!s.showMenubarIcon) {
      await TrayService().destroy();
    }
  }

  TimeOfDay _parseTime(String t) {
    final parts = t.split(':');
    final h = int.tryParse(parts[0]) ?? 8;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return TimeOfDay(hour: h, minute: m);
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 即时保存单个/多个设置字段
  Future<void> _saveSettings(Map<String, dynamic> changes) async {
    if (!_loaded) return;
    try {
      await ref.read(apiClientProvider).updateSettings(changes);
      // 同步本地 provider 状态
      final notifier = ref.read(settingsProvider.notifier);
      final current = ref.read(settingsProvider);
      final merged = AppSettings(
        username: current.username,
        // 密码不再进入设置对象（后端安全存储持有），保持 hasPassword 标记
        password: '',
        hasPassword: current.hasPassword,
        rememberMe: current.rememberMe,
        notifyMode: (changes['notify_mode'] as String?) ?? current.notifyMode,
        startTime: (changes['start_time'] as String?) ?? current.startTime,
        endTime: (changes['end_time'] as String?) ?? current.endTime,
        intervalSeconds:
            (changes['interval_seconds'] as int?) ?? current.intervalSeconds,
        autoStart: (changes['auto_start'] as bool?) ?? current.autoStart,
        autoMonitorEnabled:
            (changes['auto_monitor_enabled'] as bool?) ??
            current.autoMonitorEnabled,
        rankMonitorEnabled:
            (changes['rank_monitor_enabled'] as bool?) ??
            current.rankMonitorEnabled,
        showMenubarIcon:
            (changes['show_menubar_icon'] as bool?) ?? current.showMenubarIcon,
        hideUnknownCourses:
            (changes['hide_unknown_courses'] as bool?) ??
            current.hideUnknownCourses,
        randomIntervalEnabled:
            (changes['random_interval_enabled'] as bool?) ??
            current.randomIntervalEnabled,
        welcomeCompleted: current.welcomeCompleted,
        showWelcomeAlways: current.showWelcomeAlways,
      );
      await notifier.saveSettings(merged);
    } catch (_) {}
  }

  // ── 账号区 ──

  /// 已登录：只显示学号与「退出登录」，不再展示密码输入框
  Widget _buildAccountRow(ColorScheme colorScheme) {
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: colorScheme.primary.withValues(alpha: .12),
          child: Icon(
            Icons.person_rounded,
            size: 24,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '学号',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                _usernameCtrl.text.isEmpty ? '未绑定' : _usernameCtrl.text,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .5,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _isLoggingOut ? null : _logout,
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.error,
            side: BorderSide(color: colorScheme.error.withValues(alpha: .45)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          icon: _isLoggingOut
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.error,
                  ),
                )
              : const Icon(Icons.logout_rounded, size: 18),
          label: Text(_isLoggingOut ? '退出中...' : '退出登录'),
        ),
      ],
    );
  }

  /// 未登录（刚退出登录、或凭据缺失）：显示登录表单
  Widget _buildLoginForm(ColorScheme colorScheme) {
    return Column(
      children: [
        // 登录入口选择（教务系统 / CAS / 传统）
        if (_loginModes.isNotEmpty)
          Row(
            children: [
              Text(
                '登录入口',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurface.withValues(alpha: .6),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: _loginMode,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: _loginModes
                      .map(
                        (m) => DropdownMenuItem(
                          value: m.id,
                          child: Text(
                            m.needsCaptcha ? '${m.name}（需验证码）' : m.name,
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _onLoginModeChanged,
                ),
              ),
            ],
          ),
        if (_loginModes.isNotEmpty) const SizedBox(height: 8),
        TextField(
          controller: _usernameCtrl,
          decoration: const InputDecoration(
            labelText: '学号',
            hintText: '输入教务系统学号',
            prefixIcon: Icon(Icons.badge_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passwordCtrl,
          obscureText: _hidePassword,
          keyboardType: TextInputType.visiblePassword,
          enableSuggestions: false,
          autocorrect: false,
          enableIMEPersonalizedLearning: false,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\x00-\x7F]')),
          ],
          decoration: InputDecoration(
            labelText: '密码',
            hintText: _hasSavedPassword
                ? '已保存密码（留空则保持不变）'
                : '输入教务系统密码（仅英文/数字/符号）',
            prefixIcon: const Icon(Icons.key_rounded, size: 20),
            suffixIcon: IconButton(
              icon: Icon(
                _hidePassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 20,
              ),
              onPressed: () => setState(() => _hidePassword = !_hidePassword),
            ),
          ),
        ),
        if (_showCaptcha) ...[
          const SizedBox(height: 14),
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
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '验证码',
                    hintText: '4 位数字',
                    counterText: '',
                    prefixIcon: Icon(Icons.verified_rounded, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _captchaLoading ? null : _refreshCaptcha,
                child: Container(
                  width: 116,
                  height: 46,
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
                            color: colorScheme.onSurface.withValues(alpha: .55),
                          ),
                        )
                      : Image.memory(
                          base64Decode(
                            _captchaImage.contains(',')
                                ? _captchaImage.split(',').last
                                : _captchaImage,
                          ),
                          width: 108,
                          height: 42,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '看不清？点击图片刷新验证码',
              style: TextStyle(
                fontSize: 11.5,
                color: colorScheme.onSurface.withValues(alpha: .5),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Checkbox(
              value: _rememberMe,
              onChanged: (v) => setState(() => _rememberMe = v ?? false),
            ),
            GestureDetector(
              onTap: () => setState(() => _rememberMe = !_rememberMe),
              child: Text(
                '记住密码',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurface.withValues(alpha: .6),
                ),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _isLoggingIn ? null : _testLogin,
              icon: _isLoggingIn
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.login_rounded, size: 18),
              label: Text(_isLoggingIn ? '验证中...' : '登录并保存'),
            ),
          ],
        ),
      ],
    );
  }

  /// 退出登录：后端停监控 + 清除凭据 + 重置欢迎标记，前端切回欢迎向导
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text(
          '将停止成绩监控并清除已保存的学号与密码。\n'
          '已缓存的成绩和排名会保留，不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isLoggingOut = true);
    try {
      await ref.read(apiClientProvider).logout();
      _log.info('已退出登录');

      // 同步前端状态：清空学号与密码标记，避免界面仍显示旧学号
      _usernameCtrl.text = '';
      _passwordCtrl.text = '';
      _hasSavedPassword = false;
      _rememberMe = false;
      final notifier = ref.read(settingsProvider.notifier);
      final current = ref.read(settingsProvider);
      await notifier.saveSettings(
        current.copyWith(
          username: '',
          password: '',
          hasPassword: false,
          rememberMe: false,
          welcomeCompleted: false,
        ),
      );
      // 停掉本地监控状态显示
      await ref.read(monitorProvider.notifier).fetchStatus();

      if (mounted) {
        setState(() => _loggedIn = false);
        ToastHost().show('已退出登录');
      }
      // 通知导航层切回欢迎向导，让用户重新登录
      SessionService.notifyLogout();
    } catch (e) {
      _log.error('退出登录失败', e);
      if (mounted) ToastHost().show('退出登录失败：$e');
    } finally {
      if (mounted) setState(() => _isLoggingOut = false);
    }
  }

  /// 切换监控启停，同步后台服务
  Future<void> _syncMonitor() async {
    try {
      if (_autoMonitor || _rankMonitor) {
        await ref.read(monitorProvider.notifier).startMonitor();
      } else {
        await ref.read(monitorProvider.notifier).stopMonitor();
      }
    } catch (_) {}
  }

  // ── 各个控件的即时保存回调 ──

  void _onAutoMonitorChanged(bool v) {
    _autoMonitor = v;
    setState(() {});
    _saveSettings({'auto_monitor_enabled': v});
    _syncMonitor();
  }

  void _onRankMonitorChanged(bool v) {
    _rankMonitor = v;
    setState(() {});
    _saveSettings({'rank_monitor_enabled': v});
    _syncMonitor();
  }

  void _onIntervalChanged(double v) {
    _intervalValue = v;
    setState(() {});
  }

  void _onIntervalChangeEnd(double v) {
    _saveSettings({'interval_seconds': v.toInt()});
  }

  void _onSafeModeChanged(bool v) {
    _safeMode = v;
    setState(() {});
    _saveSettings({'random_interval_enabled': v});
  }

  Future<void> _onStartTimeChanged(TimeOfDay t) async {
    _startTime = t;
    setState(() {});
    _saveSettings({'start_time': _formatTime(t)});
  }

  Future<void> _onEndTimeChanged(TimeOfDay t) async {
    _endTime = t;
    setState(() {});
    _saveSettings({'end_time': _formatTime(t)});
  }

  void _onNotifyModeChanged(String mode) {
    _notifyMode = mode;
    setState(() {});
    _saveSettings({'notify_mode': mode});
  }

  void _onAutoStartChanged(bool v) {
    _autoStart = v;
    setState(() {});
    _saveSettings({'auto_start': v});
  }

  void _onMenubarIconChanged(bool v) {
    _showMenubarIcon = v;
    setState(() {});
    _saveSettings({'show_menubar_icon': v});
    if (v) {
      TrayService().init();
    } else {
      TrayService().destroy();
    }
  }

  void _onHideUnknownChanged(bool v) {
    _hideUnknownCourses = v;
    setState(() {});
    _saveSettings({'hide_unknown_courses': v});
  }

  /// 加载登录入口列表，并按当前入口决定是否预取验证码
  Future<void> _loadLoginModes() async {
    final modes = await ref.read(settingsProvider.notifier).fetchLoginModes();
    if (!mounted) return;
    var selected = _loginMode;
    if (modes.isNotEmpty && !modes.any((m) => m.id == selected)) {
      selected = modes
          .firstWhere((m) => m.recommended, orElse: () => modes.first)
          .id;
    }
    setState(() {
      _loginModes = modes;
      _loginMode = selected;
      _syncModeCaptcha();
    });
  }

  /// 入口变化后同步验证码状态
  void _syncModeCaptcha() {
    final hit = _loginModes.where((m) => m.id == _loginMode);
    _modeNeedsCaptcha = hit.isNotEmpty && hit.first.needsCaptcha;
    if (_showCaptcha) {
      _refreshCaptcha();
    } else {
      _captchaId = '';
      _captchaImage = '';
      _captchaCtrl.clear();
    }
  }

  void _onLoginModeChanged(String? id) {
    if (id == null || id == _loginMode) return;
    setState(() {
      _loginMode = id;
      _captchaRequiredByServer = false;
      _syncModeCaptcha();
    });
  }

  /// 拉取新验证码
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
  }

  Future<void> _testLogin() async {
    setState(() {
      _isLoggingIn = true;
    });
    final result = await ref
        .read(settingsProvider.notifier)
        .login(
          _usernameCtrl.text.trim(),
          _passwordCtrl.text,
          mode: _loginMode,
          captcha: _captchaCtrl.text.trim(),
          captchaId: _captchaId,
        );
    // 后端要求验证码（教务系统风控）：补出输入框并取码
    if (!result.success && result.captchaRequired && !_showCaptcha) {
      if (mounted) {
        setState(() {
          _captchaRequiredByServer = true;
          _syncModeCaptcha();
        });
      }
    } else if (!result.success && _showCaptcha) {
      _refreshCaptcha();
    }
    if (result.success) {
      final notifier = ref.read(settingsProvider.notifier);
      final current = ref.read(settingsProvider);
      final updated = current.copyWith(
        username: _usernameCtrl.text.trim(),
        // 密码已由 login() 直接写入后端安全存储；此处不再回传，
        // 避免设置对象（密码为空）覆盖掉刚保存的凭据。
        hasPassword: true,
        rememberMe: _rememberMe,
        loginMode: _loginMode,
        autoMonitorEnabled: _autoMonitor,
        rankMonitorEnabled: _rankMonitor,
        intervalSeconds: _intervalValue.toInt(),
        startTime: _formatTime(_startTime),
        endTime: _formatTime(_endTime),
        notifyMode: _notifyMode,
        autoStart: _autoStart,
        showMenubarIcon: _showMenubarIcon,
        hideUnknownCourses: _hideUnknownCourses,
      );
      await notifier.saveSettings(updated);
      // 登录成功后账号区切换成「学号 + 退出登录」，并清空密码输入框
      _passwordCtrl.text = '';
      _hasSavedPassword = true;
    }

    if (mounted) {
      ToastHost().show(result.message);
    }

    setState(() {
      _isLoggingIn = false;
      if (result.success) _loggedIn = true;
    });
  }

  // ── 检查更新 ──

  String get _versionDisplay {
    final v = UpdateService().currentVersion;
    return v.isEmpty ? '…' : v;
  }

  Future<void> _checkUpdate() async {
    // 程序已被禁用时直接 return
    if (UpdateService.disabled.value) return;

    setState(() {
      _updateStatus = _UpdateStatus.checking;
      _updateMessage = '检查中…';
    });

    final result = await UpdateService().checkForUpdate();
    if (!mounted) return;

    setState(() {
      if (!result.ok) {
        _updateStatus = _UpdateStatus.failed;
        _updateMessage = '检查失败：${result.error}';
      } else if (result.hasUpdate) {
        _updateStatus = _UpdateStatus.hasUpdate;
        _updateMessage = '检测到版本更新：${result.latestVersion}';
      } else {
        _updateStatus = _UpdateStatus.upToDate;
        _updateMessage = '当前已是最新版本。';
      }
    });

    if (result.ok && result.hasUpdate && mounted) {
      _showUpdateDialog(result);
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    showDialog<void>(
      context: context,
      builder: (_) => _UpdateInfoDialog(result: result),
    );
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  // ── 时间选择器 ──

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
      helpText: '选择开始时间',
      builder: (ctx, child) => Localizations.override(
        context: ctx,
        delegates: const [_ZhMaterialLocalizationsDelegate()],
        child: child,
      ),
    );
    if (picked != null) await _onStartTimeChanged(picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
      helpText: '选择结束时间',
      builder: (ctx, child) => Localizations.override(
        context: ctx,
        delegates: const [_ZhMaterialLocalizationsDelegate()],
        child: child,
      ),
    );
    if (picked != null) await _onEndTimeChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 44, 28, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '设置',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 20),

              // ---- ① 账号（无分组标题：头像与学号本身已足够说明）----
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: _loggedIn
                    ? _buildAccountRow(colorScheme)
                    : _buildLoginForm(colorScheme),
              ),
              const SizedBox(height: 24),

              // ---- ② 监控内容 ----
              _SectionTitle(title: '监控内容', icon: Icons.timer_rounded),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '成绩自动监控',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      value: _autoMonitor,
                      onChanged: _onAutoMonitorChanged,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '排名自动监控',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      value: _rankMonitor,
                      onChanged: _onRankMonitorChanged,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ---- ③ 监控时间 ----
              _SectionTitle(title: '监控时间', icon: Icons.schedule_rounded),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 提示语放在开始/结束时间之上
                    NoteBanner.info(
                      persistKey: 'settings_monitor_time_tip',
                      title: '提示',
                      text:
                          '通常，教师会在8:00至20:00之间录入并发布成绩。'
                          '为避免给服务器造成过大负载，程序仅允许您最低设置 300 秒查询一次。'
                          '如您有特殊需求，请联系开发者。',
                    ),
                    const SizedBox(height: 14),
                    // 两个时间项：各自一张浅色圆角卡（标题在左上、大号时间在下、
                    // 右下角一个展开箭头），中间用「至」连接，全程不画分割线
                    Row(
                      children: [
                        Expanded(
                          child: _TimeFieldCard(
                            title: '开始时间',
                            value: _startTime.format(context),
                            onTap: _pickStartTime,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            '至',
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.onSurface.withValues(
                                alpha: .45,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _TimeFieldCard(
                            title: '结束时间',
                            value: _endTime.format(context),
                            onTap: _pickEndTime,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '轮询间隔: ${_intervalValue.toInt()} 秒',
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.onSurface.withValues(
                                alpha: .5,
                              ),
                            ),
                          ),
                          Slider(
                            value: _intervalValue,
                            min: 300,
                            max: 3600,
                            divisions: 33,
                            label: '${_intervalValue.toInt()}秒',
                            onChanged: _onIntervalChanged,
                            onChangeEnd: _onIntervalChangeEnd,
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '300s',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onSurface.withValues(
                                    alpha: .3,
                                  ),
                                ),
                              ),
                              Text(
                                '3600s',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onSurface.withValues(
                                    alpha: .3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '安全模式',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '在设定轮询间隔的 ±100 秒范围内随机取值查询，'
                        '开启以降低账号被风控的风险。',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurface.withValues(alpha: .45),
                        ),
                      ),
                      value: _safeMode,
                      onChanged: _onSafeModeChanged,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ---- ④ 通知设置 ----
              _SectionTitle(title: '通知设置', icon: Icons.notifications_rounded),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: ['详细', '简洁'].map((mode) {
                    return InkWell(
                      onTap: () => _onNotifyModeChanged(mode),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        child: Row(
                          children: [
                            Radio<String>(
                              value: mode,
                              groupValue: _notifyMode,
                              onChanged: (v) => _onNotifyModeChanged(v ?? '详细'),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              mode == '详细'
                                  ? '完整模式：显示课程名称、成绩与位次'
                                  : '简洁模式：仅显示有成绩或位次更新',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 24),

              // ---- ⑤ 高级设置 ----
              _SectionTitle(title: '高级设置', icon: Icons.tune_rounded),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '开机自启动',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      value: _autoStart,
                      onChanged: _onAutoStartChanged,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '菜单栏图标',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      value: _showMenubarIcon,
                      onChanged: _onMenubarIconChanged,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '隐藏未知课程',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      value: _hideUnknownCourses,
                      onChanged: _onHideUnknownChanged,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ---- ⑥ 检查更新 ----
              _SectionTitle(
                title: '检查更新',
                icon: Icons.system_update_alt_rounded,
              ),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_download_rounded,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 16),
                    // 去掉「检查更新」重复标题，只留版本号
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _versionDisplay,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          if (_updateStatus != _UpdateStatus.idle) ...[
                            const SizedBox(height: 6),
                            Text(
                              _updateMessage,
                              style: TextStyle(
                                fontSize: 12,
                                color: _updateStatus == _UpdateStatus.checking
                                    ? colorScheme.onSurface.withValues(
                                        alpha: .45,
                                      )
                                    : _updateStatus == _UpdateStatus.failed
                                    ? AppTheme.error
                                    : AppTheme.success,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _updateStatus == _UpdateStatus.checking
                          ? null
                          : _checkUpdate,
                      icon: _updateStatus == _UpdateStatus.checking
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded, size: 16),
                      label: Text(
                        _updateStatus == _UpdateStatus.checking
                            ? '检查中…'
                            : '立即检查',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── 版本与版权 ──
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: .25),
                      ),
                      children: [
                        TextSpan(text: 'Version: $_versionDisplay · '),
                        const TextSpan(
                          text:
                              'Copyright © 2024-2030 GradeMonitor for RUC. All rights reserved. · ',
                        ),
                        TextSpan(
                          text: 'Github',
                          style: TextStyle(
                            color: colorScheme.primary.withValues(alpha: .5),
                            decoration: TextDecoration.underline,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () => UpdateService().openInBrowser(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自动检查（开启程序/每小时）发现新版本时由主壳调用，弹同一个更新弹窗
void showUpdateFoundDialog(BuildContext context, UpdateCheckResult result) {
  showDialog<void>(
    context: context,
    builder: (_) => _UpdateInfoDialog(result: result),
  );
}

/// 当前版本高于 GitHub 最新 Release（预发行副本）时由主壳调用
void showPreReleaseDialog(BuildContext context, UpdateCheckResult result) {
  showDialog<void>(
    context: context,
    builder: (_) => _PreReleaseDialog(result: result),
  );
}

/// 「您可能在使用预发行版本」弹窗
///
/// 触发条件：本机版本号 > GitHub 最新正式 Release 版本号，说明用户装的是
/// 开发者尚未正式发布的预览副本（或版本号被手动改过）。用红色警示样式，
/// 同时提供「下载正式版」直达最新 Release 页面。
class _PreReleaseDialog extends StatelessWidget {
  final UpdateCheckResult result;
  const _PreReleaseDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    final current = UpdateService().currentVersion;
    final latest = result.latestVersion;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final danger = isDark ? const Color(0xFFFF6B6B) : const Color(0xFFD32F2F);

    return AlertDialog(
      // 底色跟随主题：浅色纯白、深色用卡片色，避免深色下出现刺眼白块
      backgroundColor: isDark ? AppTheme.darkSurface : Colors.white,
      surfaceTintColor: Colors.transparent,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 图标独占一行且放大；标题换行到图标下方，两者均左对齐
            Icon(Icons.warning_rounded, color: danger, size: 56),
            const SizedBox(height: 14),
            Text(
              '您可能正在使用未发行的版本',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                height: 1.25,
                color: danger,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '您所使用的版本超过了当前开发者发布的最新版本。',
              style: TextStyle(fontSize: 13.5, height: 1.6),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: danger.withValues(alpha: .07),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _kvRow('当前版本号', current.isEmpty ? '未知' : current, danger),
                  const SizedBox(height: 6),
                  _kvRow(
                    'GitHub 最新 Release',
                    latest.isEmpty ? '未知' : latest,
                    danger,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '如您正在使用开发者提供的预览副本，请忽略该消息；'
              '否则，请点击「下载正式版」按钮重新安装正式版本。',
              style: TextStyle(fontSize: 13.5, height: 1.6),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('好'),
        ),
        FilledButton.icon(
          // 去 GitHub 下载：主色蓝按钮（警示只体现在标题与版本信息上）
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
          ),
          onPressed: () {
            Navigator.of(context).pop();
            UpdateService().openInBrowser(
              '${UpdateService.repoUrl}/releases/latest',
            );
          },
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('下载正式版'),
        ),
      ],
    );
  }

  Widget _kvRow(String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 148,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color.withValues(alpha: .85),
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 「发现新版本」弹窗：
/// - 更新日志以 Markdown 渲染（配合 flutter_markdown_plus）
/// - 支持应用内直接下载安装包（不跳转浏览器），带进度与完成后定位
/// - 下载完成后可一键「退出即装」：解包校验 → 退出应用 → 自动替换安装并重启
///   （仅限本机可自动安装的场景，失败自动提示手动安装）
class _UpdateInfoDialog extends StatefulWidget {
  final UpdateCheckResult result;
  const _UpdateInfoDialog({required this.result});

  @override
  State<_UpdateInfoDialog> createState() => _UpdateInfoDialogState();
}

enum _DownloadPhase {
  idle,
  downloading,
  done,
  preparing,
  installing,
  manual,
  failed,
}

class _UpdateInfoDialogState extends State<_UpdateInfoDialog> {
  final _log = AppLogger('update_ui');

  late final ReleaseAsset? _asset = UpdateService().pickPlatformAsset(
    widget.result.assets,
  );

  _DownloadPhase _phase = _DownloadPhase.idle;
  double _progress = 0; // 0..1
  String? _savedPath;
  String _errorText = '';

  /// 当前 failed 阶段是「签名校验未通过」而非下载失败
  bool _verifyFailed = false;

  /// 手动安装指引（自动安装不可用时的原因）
  String _installHint = '';

  bool get _busy =>
      _phase == _DownloadPhase.downloading ||
      _phase == _DownloadPhase.preparing ||
      _phase == _DownloadPhase.installing;

  /// 更新日志（已剔除机器用的签名清单块）
  String get _notesText =>
      UpdateVerifier.stripManifestBlocks(widget.result.releaseNotes);

  bool get _notesEmpty => _notesText.trim().isEmpty;

  /// 当前版本号文案（弹窗独立于设置页类，需自行计算）
  String get _versionDisplay {
    final v = UpdateService().currentVersion;
    return v.isEmpty ? '…' : v;
  }

  /// 未找到本平台安装包时可退回浏览器下载
  bool get _browserOnly => _asset == null;

  Future<void> _startDownload() async {
    if (_asset == null || _phase == _DownloadPhase.downloading) return;
    setState(() {
      _phase = _DownloadPhase.downloading;
      _errorText = '';
      _verifyFailed = false;
      _progress = 0;
    });
    try {
      final path = await UpdateService().downloadRelease(
        _asset,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? received / total : 0);
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.done;
        _savedPath = path;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.failed;
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// 「立即安装并重启」：**先做发布包签名校验** → 解包校验 → 退出应用
  /// → 看守脚本自动替换安装并重启。
  ///
  /// 签名校验失败（含「发布方未提供清单」）一律**拒绝自动安装**并降级为
  /// 手动安装：这可以挡住「GitHub 账号/Release 资产被替换」的供应链攻击，
  /// 因为它改不动写死在客户端里的 Ed25519 公钥。
  Future<void> _startInstall() async {
    if (_savedPath == null || _busy) return;
    setState(() {
      _phase = _DownloadPhase.preparing;
      _installHint = '';
    });

    final manifest = widget.result.manifestFor(_asset);
    if (manifest == null) {
      setState(() {
        _phase = _DownloadPhase.manual;
        _installHint =
            '该版本未提供与本安装包对应的签名清单，无法验证完整性，'
            '已停止自动安装。请手动安装并自行确认来源。';
      });
      return;
    }

    final check = await UpdateVerifier.verifyDownloadedFile(
      _savedPath!,
      manifest,
    );
    if (!mounted) return;
    if (!check.ok) {
      setState(() {
        _phase = _DownloadPhase.failed;
        _errorText = '安装包校验失败：${check.reason}';
        _installHint =
            '校验未通过，已阻止自动安装。请删除该文件后重新下载，'
            '或前往官方下载页手动获取。';
        _verifyFailed = true;
      });
      return;
    }
    _log.info('安装包签名校验通过: ${manifest.file}');

    final outcome = await UpdateInstaller().prepareInstall(_savedPath!);
    if (!mounted) return;

    final plan = outcome.plan;
    if (plan == null) {
      setState(() {
        _phase = _DownloadPhase.manual;
        _installHint = outcome.reason;
      });
      return;
    }

    setState(() => _phase = _DownloadPhase.installing);
    // 稍作停留让用户看到「即将重启」提示，随后应用将退出
    await Future.delayed(const Duration(milliseconds: 800));
    await UpdateInstaller().quitAndInstall(plan);
    // 到这一步应用应已退出；若未退出（异常），提供手动定位入口
    if (!mounted) return;
    setState(() {
      _phase = _DownloadPhase.manual;
      _installHint = '自动安装未能完成，请手动操作';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('发现新版本'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '新版本 ${widget.result.latestVersion} 已发布，'
              '当前版本 $_versionDisplay。',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            if (!_notesEmpty) ...[
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: .5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: _notesText,
                    softLineBreak: true,
                    styleSheet: _mdStyle(context),
                  ),
                ),
              ),
            ],
            ..._buildDownloadSection(context),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后再说'),
        ),
        // 本平台无安装包时，浏览器是唯一途径；有安装包时降为次按钮
        TextButton(
          onPressed: () {
            UpdateService().openInBrowser(
              '${UpdateService.repoUrl}/releases/latest',
            );
          },
          child: const Text('前往下载页'),
        ),
        if (_asset != null)
          FilledButton.icon(
            onPressed: _busy ? null : _onPrimary,
            icon:
                _phase == _DownloadPhase.downloading ||
                    _phase == _DownloadPhase.preparing ||
                    _phase == _DownloadPhase.installing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_switchIcon(), size: 18),
            label: Text(_primaryLabel()),
          ),
      ],
    );
  }

  IconData _switchIcon() {
    switch (_phase) {
      case _DownloadPhase.done:
        return Icons.restart_alt_rounded;
      case _DownloadPhase.manual:
        return Icons.folder_open_rounded;
      case _DownloadPhase.failed:
        return Icons.refresh_rounded;
      default:
        return Icons.download_rounded;
    }
  }

  String _primaryLabel() {
    switch (_phase) {
      case _DownloadPhase.downloading:
        return '正在下载…';
      case _DownloadPhase.done:
        return '立即安装并重启';
      case _DownloadPhase.preparing:
        return '正在准备安装…';
      case _DownloadPhase.installing:
        return '即将重启安装…';
      case _DownloadPhase.manual:
        return '打开所在文件夹';
      case _DownloadPhase.failed:
        return _verifyFailed ? '重新下载' : '重试下载';
      case _DownloadPhase.idle:
        return '直接下载';
    }
  }

  /// 主按钮行为随阶段变化
  Future<void> _onPrimary() async {
    switch (_phase) {
      case _DownloadPhase.idle:
      case _DownloadPhase.failed:
        await _startDownload();
      case _DownloadPhase.done:
        await _startInstall();
      case _DownloadPhase.manual:
        if (_savedPath != null) {
          await UpdateService().revealInFileManager(_savedPath!);
        }
      case _DownloadPhase.downloading:
      case _DownloadPhase.preparing:
      case _DownloadPhase.installing:
        return;
    }
  }

  /// 下载进度 / 结果提示区
  List<Widget> _buildDownloadSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final asset = _asset;
    final nameLabel = asset?.name ?? '';
    final assetSizeMb = asset != null && asset.size > 0
        ? '（约 ${(asset.size / 1024 / 1024).toStringAsFixed(1)} MB）'
        : '';
    final sub = TextStyle(
      fontSize: 12.5,
      height: 1.5,
      color: cs.onSurface.withValues(alpha: .6),
    );
    if (_browserOnly) {
      return [
        const SizedBox(height: 10),
        Text('未找到本平台的自动下载安装包，请通过「前往下载页」手动下载。', style: sub),
      ];
    }
    switch (_phase) {
      case _DownloadPhase.idle:
        return [
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.save_alt_rounded,
                size: 14,
                color: cs.onSurface.withValues(alpha: .45),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '将直接下载 $nameLabel$assetSizeMb 到系统的「下载」文件夹',
                  style: sub,
                ),
              ),
            ],
          ),
        ];
      case _DownloadPhase.downloading:
        return [
          const SizedBox(height: 14),
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          const SizedBox(height: 6),
          Text(
            _progress > 0 ? '${(_progress * 100).toStringAsFixed(0)}%' : '连接中…',
            style: sub,
          ),
        ];
      case _DownloadPhase.done:
        return [
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: AppTheme.success,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text('已下载到「下载」文件夹：$nameLabel', style: sub)),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Text(
              widget.result.manifestFor(_asset) != null
                  ? '点击「立即安装并重启」后，应用会先校验安装包的发布签名，'
                        '通过后自动完成安装并重新打开（安装过程中会短暂关闭）。'
                  : '该版本未提供与本安装包对应的签名清单，自动安装将被拒绝，'
                        '请手动安装并自行确认来源。',
              style: sub,
            ),
          ),
        ];
      case _DownloadPhase.preparing:
        return [
          const SizedBox(height: 10),
          LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text('正在解包校验安装内容…', style: sub),
        ];
      case _DownloadPhase.installing:
        return [
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('正在退出应用并自动替换安装，请勿关闭此窗口。', style: sub)),
            ],
          ),
        ];
      case _DownloadPhase.manual:
        return [
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: AppTheme.warning,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text('自动安装未完成：$_installHint', style: sub)),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Text(
              '已为你定位到下载文件：'
              'Windows 双击安装包完成升级；macOS 请将新版 App 替换现有位置。',
              style: sub,
            ),
          ),
        ];
      case _DownloadPhase.failed:
        return [
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 16,
                color: AppTheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _verifyFailed ? _errorText : '下载失败：$_errorText',
                  style: sub,
                ),
              ),
            ],
          ),
          if (_verifyFailed && _installHint.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Text(_installHint, style: sub),
            ),
          ],
        ];
    }
  }

  /// Markdown 样式：贴合弹窗小字排版
  MarkdownStyleSheet _mdStyle(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = cs.onSurface;
    base(String? weight) => TextStyle(
      fontSize: 12.5,
      height: 1.55,
      fontWeight: weight == null ? FontWeight.w400 : FontWeight.w700,
      color: on.withValues(alpha: .78),
    );
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      a: TextStyle(
        fontSize: 12.5,
        color: cs.primary,
        decoration: TextDecoration.underline,
      ),
      p: base(null),
      h1: base('700').copyWith(fontSize: 18, color: on, height: 1.4),
      h2: base('700').copyWith(fontSize: 16, color: on, height: 1.4),
      h3: base('700').copyWith(fontSize: 14.5, color: on, height: 1.4),
      h4: base('700').copyWith(fontSize: 13.5, color: on),
      h5: base('700').copyWith(fontSize: 13, color: on),
      h6: base('700').copyWith(fontSize: 12.5, color: on),
      strong: base('700').copyWith(color: on),
      em: base(null).copyWith(fontStyle: FontStyle.italic),
      listBullet: base(null),
      blockSpacing: 8,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: on.withValues(alpha: .18), width: 1),
        ),
      ),
      code: TextStyle(
        fontSize: 11.5,
        color: on.withValues(alpha: .9),
        fontFamily: 'monospace',
      ),
      codeblockDecoration: BoxDecoration(
        color: on.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(8),
      ),
      blockquote: base(null).copyWith(color: on.withValues(alpha: .55)),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: cs.primary.withValues(alpha: .5), width: 3),
        ),
      ),
    );
  }
}

/// 检查更新状态（四态 + 空闲初始态）
enum _UpdateStatus { idle, checking, upToDate, hasUpdate, failed }

/// 时间选择卡片：左上小标题、下方大号时间、右下角展开箭头。
/// 只靠底色与圆角成形，不画任何边框/分割线。
class _TimeFieldCard extends StatelessWidget {
  final String title;
  final String value;
  final VoidCallback onTap;

  const _TimeFieldCard({
    required this.title,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.onSurface.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 10, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                          letterSpacing: -.5,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: colorScheme.onSurface.withValues(alpha: .38),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分区标题
class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: colorScheme.primary),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

/// 时间选择弹窗中文文案（项目未引入 flutter_localizations，
/// 这里在 showTimePicker 的 builder 里局部覆盖 Material 默认英文文案）
class _ZhMaterialLocalizations extends DefaultMaterialLocalizations {
  const _ZhMaterialLocalizations();

  @override
  String get cancelButtonLabel => '取消';

  @override
  String get okButtonLabel => '好';

  @override
  String get timePickerDialHelpText => '选择时间';

  @override
  String get timePickerInputHelpText => '输入时间';

  @override
  String get timePickerHourModeAnnouncement => '选择小时';

  @override
  String get timePickerMinuteModeAnnouncement => '选择分钟';

  @override
  String get anteMeridiemAbbreviation => '上午';

  @override
  String get postMeridiemAbbreviation => '下午';
}

class _ZhMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _ZhMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      SynchronousFuture<MaterialLocalizations>(
        const _ZhMaterialLocalizations(),
      );

  @override
  bool shouldReload(
    covariant LocalizationsDelegate<MaterialLocalizations> old,
  ) => false;
}
