import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/service/update_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../dashboard/dashboard_page.dart';
import '../disabled/disabled_page.dart';
import '../grades/grades_page.dart';
import '../settings/settings_page.dart';
import '../welcome/welcome_dialog.dart';
import '../../widgets/toast_host.dart';

enum NavDestination {
  dashboard(icon: Icons.dashboard_rounded, label: '仪表板'),
  grades(icon: Icons.school_rounded, label: '成绩单'),
  settings(icon: Icons.settings_rounded, label: '设置');

  final IconData icon;
  final String label;
  const NavDestination({required this.icon, required this.label});
}

class AppNavigation extends StatefulWidget {
  const AppNavigation({super.key});
  @override
  State<AppNavigation> createState() => _AppNavigationState();
}

class _AppNavigationState extends State<AppNavigation> {
  NavDestination _currentDest = NavDestination.dashboard;
  int _versionTapCount = 0;
  DateTime _lastVersionTap = DateTime.now();
  bool _welcomeChecked = false;

  @override
  void initState() {
    super.initState();
    // 预加载应用版本号（主页左下角精简显示用）
    UpdateService().loadCurrentVersion();
    // 首帧渲染后再检查欢迎页，确保 context 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkWelcomeWithRetry();
    });
  }

  /// 带重试的欢迎页检查（后端可能需要几秒才启动完毕）
  Future<void> _checkWelcomeWithRetry() async {
    if (_welcomeChecked) return;
    const maxRetries = 20;
    const retryDelay = Duration(milliseconds: 500);

    for (int i = 0; i < maxRetries; i++) {
      try {
        final api = ApiClient();
        final resp = await api.getWelcomeStatus();
        final data = resp.data as Map<String, dynamic>;
        final welcomeCompleted = data['welcome_completed'] as bool? ?? false;
        final showWelcomeAlways = data['show_welcome_always'] as bool? ?? false;

        _welcomeChecked = true;

        if (!welcomeCompleted || showWelcomeAlways) {
          if (mounted) {
            await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const WelcomeDialog(),
            );
          }
        }
        return; // 成功，退出重试
      } catch (_) {
        // 后端未就绪，继续重试
        if (i < maxRetries - 1) {
          await Future.delayed(retryDelay);
        }
      }
    }
  }

  Widget _buildPage(NavDestination dest) {
    switch (dest) {
      case NavDestination.dashboard:
        return const DashboardPage();
      case NavDestination.grades:
        return const GradesPage();
      case NavDestination.settings:
        return const SettingsPage();
    }
  }

  void _onVersionTap() {
    final now = DateTime.now();
    // Reset if more than 1 second since last tap
    if (now.difference(_lastVersionTap).inMilliseconds > 1000) {
      _versionTapCount = 0;
    }
    _lastVersionTap = now;
    _versionTapCount++;
    if (_versionTapCount >= 3) {
      _versionTapCount = 0;
      _showDevToolsDialog();
    }
  }

  void _showDevToolsDialog() {
    final api = ApiClient();
    final intervalCtrl = TextEditingController();

    // 使用独立的 StatefulWidget 避免 builder 闭包中的变量重置问题
    showDialog(
      context: context,
      builder: (ctx) => _DevToolsDialog(api: api, intervalCtrl: intervalCtrl),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Row(
        children: [
          Material(
            elevation: 0,
            color: colorScheme.surface.withValues(alpha: .4),
            child: SizedBox(
              width: 110,
              child: Column(
                children: [
                  const SizedBox(height: 40),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 12),
                    child: Icon(
                      Icons.search_rounded,
                      size: 28,
                      color: colorScheme.primary,
                    ),
                  ),
                  Text(
                    'Grade\nMonitor',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Divider(indent: 16, endIndent: 16),
                  const Spacer(),
                  ...NavDestination.values.map((dest) {
                    final selected = _currentDest == dest;
                    return _NavItem(
                      icon: dest.icon,
                      label: dest.label,
                      selected: selected,
                      onTap: () => setState(() => _currentDest = dest),
                    );
                  }),
                  const Spacer(),
                  const Divider(indent: 16, endIndent: 16),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16, top: 8),
                    child: GestureDetector(
                      onTap: _onVersionTap,
                      child: Text(
                        UpdateService.VerStatus.isEmpty
                            ? '…'
                            : UpdateService.VerStatus,
                        style: TextStyle(
                          fontSize: 10,
                          color: colorScheme.onSurface.withValues(alpha: .3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: .5,
            color: colorScheme.outlineVariant,
          ),
          Expanded(child: _buildPage(_currentDest)),
        ],
      ),
    );
  }
}

// ---- 独立的 DevTools 弹窗（避免 StatefulBuilder 闭包变量重置） ----

class _DevToolsDialog extends StatefulWidget {
  final ApiClient api;
  final TextEditingController intervalCtrl;

  const _DevToolsDialog({required this.api, required this.intervalCtrl});

  @override
  State<_DevToolsDialog> createState() => _DevToolsDialogState();
}

class _DevToolsDialogState extends State<_DevToolsDialog> {
  bool _loading = false;
  String? _msg;

  Future<void> _devAction(
    String label,
    Future<dynamic> Function() action,
  ) async {
    setState(() {
      _loading = true;
      _msg = null;
    });
    try {
      final resp = await action();
      final data = resp.data as Map<String, dynamic>;
      setState(() {
        _msg = '[$label] ${data['message'] ?? '操作成功'}';
      });
    } catch (e) {
      setState(() {
        _msg = '[$label] 失败: $e';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _showNotificationPreview() async {
    try {
      final resp = await widget.api.getNotificationPreview('详细');
      final preview = resp.data['preview'] as String? ?? '加载失败';
      if (mounted) {
        showDialog(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('通知预览'),
            content: Text(
              preview,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ToastHost().show('加载通知预览失败: $e');
      }
    }
  }

  Future<void> _applyCustomInterval() async {
    final val = int.tryParse(widget.intervalCtrl.text);
    if (val == null || val < 10 || val > 3600) {
      ToastHost().show('轮询间隔仅允许设置 10-3600 秒');
      return;
    }
    try {
      await widget.api.updateSettings({'interval_seconds': val});
      if (mounted) {
        ToastHost().show('轮询间隔已设为 $val 秒');
      }
    } catch (e) {
      if (mounted) {
        ToastHost().show('设置失败: $e');
      }
    }
  }

  @override
  void dispose() {
    widget.intervalCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 底色跟随系统主题：亮色纯白，深色用深底，避免深色模式下刺眼
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: isDark ? AppTheme.darkTheme : AppTheme.lightTheme,
      child: Builder(
        builder: (context) {
          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 点击“开发者选项”标题可作为禁用页 debug 入口
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DisabledScreen()),
                    );
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      '开发者选项',
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '下列设置仅允许在开发者的指导下使用，请勿随意修改',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.red.shade300 : AppTheme.error,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Version: '
                  '${UpdateService().currentVersion.isEmpty ? '…' : UpdateService().currentVersion}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── 基础功能测试 ──
                    const Text(
                      '基础功能测试',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                        letterSpacing: .5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _devBtn('测试查询功能', Icons.search_rounded, () {
                          _devAction('测试查询功能', () => widget.api.queryOnce());
                        }),
                        _devBtn(
                          '测试通知功能',
                          Icons.notifications_active_rounded,
                          () {
                            _devAction(
                              '测试通知功能',
                              () => widget.api.sendTestNotification(),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 14),
                    // ── 应用数据 ──
                    const Text(
                      '应用数据',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                        letterSpacing: .5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _devBtn('打开数据目录', Icons.folder_open_rounded, () {
                          _devAction('打开目录', () => widget.api.openLogDir());
                        }),
                        _devBtn('清理缓存', Icons.cleaning_services_rounded, () {
                          _devAction('清理缓存', () => widget.api.clearCache());
                        }),
                        _devBtnDanger('重置全部数据', Icons.dangerous_rounded, () {
                          showDialog(
                            context: context,
                            builder: (dctx) => AlertDialog(
                              title: const Text('确认重置'),
                              content: const Text('此操作将清除所有缓存与设置数据，不可恢复。'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dctx),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () {
                                    Navigator.pop(dctx);
                                    _devAction(
                                      '重置数据',
                                      () => widget.api.clearAllData(),
                                    );
                                  },
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppTheme.error,
                                  ),
                                  child: const Text('确认重置'),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 14),
                    // ── 轮询设置 ──
                    const Text(
                      '自定义轮询间隔',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                        letterSpacing: .5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: widget.intervalCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              hintText: '10-3600',
                              hintStyle: TextStyle(fontSize: 12),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '秒',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.tonalIcon(
                          onPressed: _applyCustomInterval,
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text(
                            '应用',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 14),
                    // ── 页面管理 ──
                    const Text(
                      '页面管理',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                        letterSpacing: .5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _devBtn('WelcomePageTEST', Icons.web_rounded, () {
                          showDialog(
                            context: context,
                            builder: (_) => const WelcomeDialog(),
                          );
                        }),
                        _devBtn(
                          'DisablePageTEST',
                          Icons.visibility_off_rounded,
                          () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const DisabledScreen(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    // ── 状态信息 ──
                    if (_loading || _msg != null) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (_loading)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          else
                            Icon(
                              _msg!.contains('失败')
                                  ? Icons.error_outline
                                  : Icons.check_circle_outline,
                              size: 16,
                              color: _msg!.contains('失败')
                                  ? AppTheme.error
                                  : AppTheme.success,
                            ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _loading ? '处理中...' : _msg!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _devBtn(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: Colors.grey.shade400),
        elevation: 0,
      ),
    );
  }

  Widget _devBtnDanger(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: AppTheme.error),
      label: Text(
        label,
        style: const TextStyle(fontSize: 12, color: AppTheme.error),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.error,
        side: BorderSide(color: AppTheme.error.withValues(alpha: .4)),
        elevation: 0,
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = selected
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: .45);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
      child: Material(
        color: selected
            ? colorScheme.primary.withValues(alpha: .15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          splashColor: colorScheme.primary.withValues(alpha: .2),
          highlightColor: colorScheme.primary.withValues(alpha: .08),
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: textColor),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
