import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/service/tray_service.dart';
import '../../core/service/update_installer.dart';
import '../../core/service/update_service.dart';
import '../../providers/settings_provider.dart';
import '../../providers/monitor_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/toast_host.dart';

/// 系统设置页面（所有开关即时生效）
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // 表单控制器
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _hidePassword = true;
  bool _rememberMe = false;
  bool _isLoggingIn = false;

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
    _passwordCtrl.text = s.password;
    _rememberMe = s.rememberMe;
    _hidePassword = true;
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
    _loaded = true;
    setState(() {});

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
        password: current.password,
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

  Future<void> _testLogin() async {
    setState(() {
      _isLoggingIn = true;
    });
    final result = await ref
        .read(settingsProvider.notifier)
        .login(_usernameCtrl.text.trim(), _passwordCtrl.text);
    if (result.success) {
      final notifier = ref.read(settingsProvider.notifier);
      final current = ref.read(settingsProvider);
      final updated = current.copyWith(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        rememberMe: _rememberMe,
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
    }

    if (mounted) {
      ToastHost().show(result.message);
    }

    setState(() {
      _isLoggingIn = false;
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
        _updateMessage = '检查成功，当前已经是最新版本 $_versionDisplay';
      }
    });

    if (result.ok && result.hasUpdate && mounted) {
      _showUpdateDialog(result);
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    showDialog<void>(context: context, builder: (_) => _UpdateInfoDialog(result: result));
  }


  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ── 时间选择器 ──

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
      helpText: '选择开始时间',
    );
    if (picked != null) await _onStartTimeChanged(picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
      helpText: '选择结束时间',
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
              const SizedBox(height: 6),
              Text(
                '您可以在此处调整程序的所有配置',
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 28),

              // ---- ① 账号与登录 ----
              _SectionTitle(title: '账号与登录', icon: Icons.lock_rounded),
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
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
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[\x00-\x7F]'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: '密码',
                        hintText: '输入教务系统密码（仅英文/数字/符号）',
                        prefixIcon: const Icon(Icons.key_rounded, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _hidePassword
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _hidePassword = !_hidePassword),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Checkbox(
                          value: _rememberMe,
                          onChanged: (v) =>
                              setState(() => _rememberMe = v ?? false),
                        ),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _rememberMe = !_rememberMe),
                          child: Text(
                            '记住密码',
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.onSurface.withValues(
                                alpha: .6,
                              ),
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
                ),
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
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              '开始时间',
                              style: TextStyle(fontSize: 13),
                            ),
                            trailing: Text(
                              _startTime.format(context),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: _pickStartTime,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              '结束时间',
                              style: TextStyle(fontSize: 13),
                            ),
                            trailing: Text(
                              _endTime.format(context),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: _pickEndTime,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '出成绩时间通常为 8:00-18:00；为避免给服务器造成过大压力，轮询间隔仅允许最小设置 300 秒',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: .35),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '非窗口期内监控自动休眠',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: .35),
                      ),
                    ),
                    const Divider(height: 24),
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
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.cloud_download_rounded,
                    color: colorScheme.primary,
                  ),
                  title: const Text(
                    '检查更新',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 3),
                      Text(
                        '当前版本 $_versionDisplay',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withValues(alpha: .5),
                        ),
                      ),
                      if (_updateStatus != _UpdateStatus.idle) ...[
                        const SizedBox(height: 4),
                        Text(
                          _updateMessage,
                          style: TextStyle(
                            fontSize: 12,
                            color: _updateStatus == _UpdateStatus.checking
                                ? colorScheme.onSurface.withValues(alpha: .45)
                                : _updateStatus == _UpdateStatus.failed
                                ? AppTheme.error
                                : AppTheme.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                  trailing: OutlinedButton.icon(
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
                      _updateStatus == _UpdateStatus.checking ? '检查中…' : '立即检查',
                    ),
                  ),
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
  late final ReleaseAsset? _asset = UpdateService().pickPlatformAsset(
    widget.result.assets,
  );

  _DownloadPhase _phase = _DownloadPhase.idle;
  double _progress = 0; // 0..1
  String? _savedPath;
  String _errorText = '';

  /// 手动安装指引（自动安装不可用时的原因）
  String _installHint = '';

  bool get _busy =>
      _phase == _DownloadPhase.downloading ||
      _phase == _DownloadPhase.preparing ||
      _phase == _DownloadPhase.installing;

  bool get _notesEmpty => widget.result.releaseNotes.trim().isEmpty;

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

  /// 「立即安装并重启」：解包校验 → 退出应用 → 看守脚本自动替换安装并重启。
  /// 自动安装不可用（权限/形态限制）时切换到手动安装指引。
  Future<void> _startInstall() async {
    if (_savedPath == null || _busy) return;
    setState(() {
      _phase = _DownloadPhase.preparing;
      _installHint = '';
    });
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
      title: Row(
        children: [
          Icon(Icons.upgrade_rounded, color: AppTheme.success, size: 24),
          const SizedBox(width: 10),
          const Text('发现新版本'),
        ],
      ),
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
                    data: widget.result.releaseNotes,
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
            icon: _phase == _DownloadPhase.downloading ||
                    _phase == _DownloadPhase.preparing ||
                    _phase == _DownloadPhase.installing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _switchIcon(),
                    size: 18,
                  ),
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
        return '重试下载';
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
            _progress > 0
                ? '${(_progress * 100).toStringAsFixed(0)}%'
                : '连接中…',
            style: sub,
          ),
        ];
      case _DownloadPhase.done:
        return [
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已下载到「下载」文件夹：$nameLabel',
                  style: sub,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Text(
              '点击「立即安装并重启」后，应用将自动完成安装并重新打开'
              '（安装过程中会短暂关闭）。',
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
              Expanded(
                child: Text('正在退出应用并自动替换安装，请勿关闭此窗口。', style: sub),
              ),
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
              Expanded(
                child: Text('自动安装未完成：$_installHint', style: sub),
              ),
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
              Icon(Icons.error_outline_rounded, size: 16, color: AppTheme.error),
              const SizedBox(width: 6),
              Expanded(child: Text('下载失败：$_errorText', style: sub)),
            ],
          ),
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
      a: TextStyle(fontSize: 12.5, color: cs.primary, decoration: TextDecoration.underline),
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
        border: Border(left: BorderSide(color: cs.primary.withValues(alpha: .5), width: 3)),
      ),
    );
  }
}

/// 检查更新状态（四态 + 空闲初始态）
enum _UpdateStatus { idle, checking, upToDate, hasUpdate, failed }

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
