import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../dashboard/dashboard_page.dart';
import '../grades/grades_page.dart';
import '../scheme/scheme_page.dart';
import '../settings/settings_page.dart';
import '../welcome/welcome_flow.dart';
import '../../core/service/update_service.dart';
import '../../widgets/toast_host.dart';

enum NavDestination {
  dashboard(icon: Icons.dashboard_rounded, label: '仪表板'),
  grades(icon: Icons.school_rounded, label: '成绩单'),
  scheme(icon: Icons.calculate_rounded, label: '方案计算'),
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

class _AppNavigationState extends State<AppNavigation> with WindowListener {
  NavDestination _currentDest = NavDestination.dashboard;
  bool _isMaximized = false;
  int _versionTapCount = 0;
  DateTime _lastVersionTap = DateTime.now();
  bool _devShowWelcomeAlways = false;
  bool _welcomeChecked = false;

  /// 欢迎流程阶段：checking=检查中（用同色底遮挡主界面防闪烁），
  /// welcome=欢迎向导展示中，main=进入主界面
  String _welcomePhase = 'checking';

  @override
  void initState() {
    super.initState();
    // 监听窗口事件（同步最大化状态给标题栏按钮图标）
    windowManager.addListener(this);
    // 首帧渲染后再检查欢迎页，确保 context 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkWelcomeWithRetry();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
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

        if (mounted) {
          // 检查完成后一次性决定去向，避免主界面先渲染再被欢迎页覆盖
          setState(() {
            _welcomePhase =
                (!welcomeCompleted || showWelcomeAlways) ? 'welcome' : 'main';
          });
        }
        return; // 成功，退出重试
      } catch (_) {
        // 后端未就绪，继续重试
        if (i < maxRetries - 1) {
          await Future.delayed(retryDelay);
        }
      }
    }
    // 后端始终未就绪：按主界面继续（与旧行为一致）
    if (mounted) setState(() => _welcomePhase = 'main');
  }

  /// 自定义标题栏：拖拽区 + 应用名 + 最小化/最大化/关闭
  Widget _buildTitleBar(ColorScheme colorScheme) {
    // 自定义标题栏（最小化/最大化/关闭）仅供 Windows：
    // macOS 由系统提供原生红绿灯与拖拽，不渲染 Windows 风格按钮
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }
    const barHeight = 36.0;
    return Container(
      height: barHeight,
      color: colorScheme.surface.withValues(alpha: .4),
      child: Row(
        children: [
          // 左侧拖拽区 + 应用名
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'GradeMonitor',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface.withValues(alpha: .55),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 窗口控制按钮（Windows 风格：矩形、无间距）
          _TitleBarButton(
            icon: Icons.remove_rounded,
            tooltip: '最小化',
            onTap: () => windowManager.minimize(),
          ),
          _TitleBarButton(
            icon: _isMaximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            iconSize: _isMaximized ? 14 : 15,
            tooltip: _isMaximized ? '还原' : '最大化',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _TitleBarButton(
            icon: Icons.close_rounded,
            tooltip: '关闭',
            isClose: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(NavDestination dest) {
    switch (dest) {
      case NavDestination.dashboard:
        return const DashboardPage();
      case NavDestination.grades:
        return const GradesPage();
      case NavDestination.scheme:
        return const SchemePage();
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
      builder: (ctx) => _DevToolsDialog(
        api: api,
        intervalCtrl: intervalCtrl,
        devShowWelcomeAlways: _devShowWelcomeAlways,
        onWelcomeAlwaysChanged: (v) {
          _devShowWelcomeAlways = v;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          // 自定义标题栏：拖拽区 + 应用名 + 窗口控制按钮
          _buildTitleBar(colorScheme),
          Expanded(
            child: _welcomePhase == 'checking'
                ? Container(
                    // 检查中：与欢迎页同色底遮盖主区域，
                    // 避免仪表板先渲染再被欢迎页覆盖造成闪烁
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF1C1C1E)
                        : Colors.white,
                    width: double.infinity,
                  )
                : _welcomePhase == 'welcome'
                // 欢迎向导占满标题栏以下整个窗口（iPhone 激活式逐页设置）
                ? WelcomeFlow(
                    onCompleted: () => setState(() => _welcomePhase = 'main'),
                  )
                : Row(
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
                                color: colorScheme.onSurface.withValues(
                                  alpha: .3,
                                ),
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
          ),
        ],
      ),
    );
  }
}

// ---- 独立的 DevTools 弹窗（避免 StatefulBuilder 闭包变量重置） ----

class _DevToolsDialog extends StatefulWidget {
  final ApiClient api;
  final TextEditingController intervalCtrl;
  final bool devShowWelcomeAlways;
  final ValueChanged<bool> onWelcomeAlwaysChanged;

  const _DevToolsDialog({
    required this.api,
    required this.intervalCtrl,
    required this.devShowWelcomeAlways,
    required this.onWelcomeAlwaysChanged,
  });

  @override
  State<_DevToolsDialog> createState() => _DevToolsDialogState();
}

class _DevToolsDialogState extends State<_DevToolsDialog> {
  bool _loading = false;
  String? _msg;
  bool _showWelcomeAlways = false;
  bool _welcomeLoaded = false;

  // 隐秘触发：1 秒内连续点击 3 次标题"开发者工具" → 显示禁用页
  int _titleTaps = 0;
  DateTime _lastTitleTap = DateTime.now();

  @override
  void initState() {
    super.initState();
    _showWelcomeAlways = widget.devShowWelcomeAlways;
    _loadWelcomeStatus();
  }

  /// 标题红字三连击：走与远程停用（killSwitch 114.514）相同的链路进入禁用页
  void _onTitleTap() {
    final now = DateTime.now();
    if (now.difference(_lastTitleTap).inMilliseconds > 1000) {
      _titleTaps = 0;
    }
    _lastTitleTap = now;
    _titleTaps++;
    if (_titleTaps < 3) return;
    _titleTaps = 0;
    Navigator.of(context).pop(); // 先关闭对话框，避免残留在禁用页之上
    UpdateService.disabled.value = true; // main.dart 监听后自动切换到禁用页
  }

  Future<void> _loadWelcomeStatus() async {
    try {
      final r = await widget.api.getWelcomeStatus();
      final d = r.data as Map<String, dynamic>;
      setState(() {
        _showWelcomeAlways = d['show_welcome_always'] as bool? ?? false;
        _welcomeLoaded = true;
      });
      widget.onWelcomeAlwaysChanged(_showWelcomeAlways);
    } catch (_) {
      setState(() => _welcomeLoaded = true);
    }
  }

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
    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 隐秘触发区：1 秒内三连击标题进入禁用页，无任何视觉反馈
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTitleTap,
            child: const Text('开发者工具'),
          ),
          const SizedBox(height: 4),
          const Text(
            '请在开发者指导下使用',
            style: TextStyle(fontSize: 11, color: Colors.grey),
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
              // ── 快捷操作 ──
              const Text(
                '快捷操作',
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
                  _devBtn('立即查询', Icons.rocket_launch_rounded, () {
                    _devAction('立即查询', () => widget.api.queryOnce());
                  }),
                  _devBtn('测试通知', Icons.notifications_active_rounded, () {
                    _devAction('测试通知', () => widget.api.sendTestNotification());
                  }),
                  _devBtn(
                    '通知预览',
                    Icons.preview_rounded,
                    _showNotificationPreview,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 14),
              // ── 维护操作 ──
              const Text(
                '维护操作',
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
                '自定义轮询间隔（覆盖设置页中设定的间隔时间）',
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
                        hintText: '10-300',
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
                    label: const Text('应用', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 14),
              // ── 欢迎页设置 ──
              const Text(
                '欢迎页设置',
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
                  const Text('始终在启动时弹出欢迎页：', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  SizedBox(
                    height: 32,
                    child: Checkbox(
                      value: _showWelcomeAlways,
                      onChanged: _welcomeLoaded
                          ? (v) =>
                                setState(() => _showWelcomeAlways = v ?? false)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () async {
                      try {
                        await widget.api.updateSettings({
                          'show_welcome_always': _showWelcomeAlways,
                        });
                        widget.onWelcomeAlwaysChanged(_showWelcomeAlways);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                _showWelcomeAlways ? '已开启：每次启动弹欢迎页' : '已关闭',
                              ),
                              backgroundColor: AppTheme.success,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('设置失败: $e'),
                              backgroundColor: AppTheme.error,
                            ),
                          );
                        }
                      }
                    },
                    child: const Text('保存', style: TextStyle(fontSize: 11)),
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
                          child: CircularProgressIndicator(strokeWidth: 2),
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

/// Windows 风格标题栏按钮：矩形热区，悬停变色（关闭键悬停变红）
class _TitleBarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;
  final double iconSize;

  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
    this.iconSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: isClose
              ? AppTheme.error
              : Colors.grey.withValues(alpha: .25),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: SizedBox(
            width: 44,
            height: double.infinity,
            child: Icon(
              icon,
              size: iconSize,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .75),
            ),
          ),
        ),
      ),
    );
  }
}
