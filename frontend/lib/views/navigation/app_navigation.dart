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
import '../forwarders/notification_forwarders_page.dart';
import 'developer_login_dialog.dart';
import '../welcome/welcome_flow.dart';
import '../../core/service/feature_gate_service.dart';
import '../../widgets/feature_gate.dart';
import '../../core/service/update_service.dart';
import '../../core/service/nav_signal.dart';
import '../../core/service/session_service.dart';

enum NavDestination {
  dashboard(icon: Icons.dashboard, label: '仪表板'),
  grades(icon: Icons.school, label: '成绩单'),
  scheme(icon: Icons.calculate, label: '方案计算'),
  forwarders(icon: Icons.send_to_mobile_outlined, label: '通知转发'),
  settings(icon: Icons.settings, label: '设置');

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
  bool _welcomeChecked = false;

  /// 欢迎流程阶段：checking=检查中（用同色底遮挡主界面防闪烁），
  /// welcome=欢迎向导展示中，main=进入主界面
  String _welcomePhase = 'checking';

  /// 本会话是否已自动弹过「发现新版本」（避免每小时重复打扰）
  bool _autoUpdatePrompted = false;

  /// 本会话是否已弹过「预发行版本」告警（只弹一次）
  bool _preReleasePrompted = false;

  @override
  void initState() {
    super.initState();
    // 监听窗口事件（同步最大化状态给标题栏按钮图标）
    windowManager.addListener(this);
    // 自动检查（开启程序/每小时）发现更新 → 弹「发现新版本」
    UpdateService.updateFound.addListener(_onAutoUpdateFound);
    // 当前版本高于最新 Release → 弹「您可能在使用预发行版本」
    UpdateService.preReleaseFound.addListener(_onPreReleaseFound);
    // 设置页退出登录 → 切回欢迎向导重新登录
    SessionService.logoutSignal.addListener(_onLoggedOut);
    // 跨页面导航请求（仪表板「查看完整成绩 →」等）
    navRequest.addListener(_onNavRequest);
    // 首帧渲染后再检查欢迎页，确保 context 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkWelcomeWithRetry();
      // 启动时的静默检查可能在监听挂上前已完成，补查一次
      _onAutoUpdateFound();
      _onPreReleaseFound();
    });
  }

  /// 自动检查发现新版本：欢迎流程结束后弹一次（每会话至多一次）
  void _onAutoUpdateFound() {
    final result = UpdateService.updateFound.value;
    if (result == null || _autoUpdatePrompted) return;
    if (_welcomePhase != 'main') return;
    if (!mounted) return;
    _autoUpdatePrompted = true;
    showUpdateFoundDialog(context, result);
  }

  /// 启动检查发现当前版本高于最新正式 Release：欢迎流程结束后弹一次红色告警
  void _onPreReleaseFound() {
    final result = UpdateService.preReleaseFound.value;
    if (result == null || _preReleasePrompted) return;
    if (_welcomePhase != 'main') return;
    if (!mounted) return;
    _preReleasePrompted = true;
    showPreReleaseDialog(context, result);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    UpdateService.updateFound.removeListener(_onAutoUpdateFound);
    UpdateService.preReleaseFound.removeListener(_onPreReleaseFound);
    SessionService.logoutSignal.removeListener(_onLoggedOut);
    navRequest.removeListener(_onNavRequest);
    super.dispose();
  }

  /// 响应跨页面导航请求：切换左侧导航目的地
  void _onNavRequest() {
    final target = navRequest.value;
    if (target == null) return;
    navRequest.value = null;
    if (!mounted) return;
    final dest = switch (target) {
      AppNavTarget.dashboard => NavDestination.dashboard,
      AppNavTarget.grades => NavDestination.grades,
      AppNavTarget.scheme => NavDestination.scheme,
      AppNavTarget.settings => NavDestination.settings,
    };
    if (dest == _currentDest) return;
    setState(() => _currentDest = dest);
  }

  /// 设置页退出登录后：回到欢迎向导，让用户重新登录
  void _onLoggedOut() {
    if (!mounted) return;
    setState(() {
      _currentDest = NavDestination.dashboard;
      _welcomePhase = 'welcome';
    });
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
          final phase = (!welcomeCompleted || showWelcomeAlways)
              ? 'welcome'
              : 'main';
          setState(() => _welcomePhase = phase);
          // 直接进主界面时，启动静默检查可能早已完成（监听回调因当时还在
          // checking 阶段被跳过），这里补触发两个告警
          if (phase == 'main') {
            _onAutoUpdateFound();
            _onPreReleaseFound();
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
    // 后端始终未就绪：按主界面继续（与旧行为一致）
    if (mounted) {
      setState(() => _welcomePhase = 'main');
      _onAutoUpdateFound();
      _onPreReleaseFound();
    }
  }

  /// 自定义标题栏：拖拽区 + 应用名 + 最小化/最大化/关闭
  Widget _buildTitleBar(ColorScheme colorScheme) {
    // 自定义标题栏（最小化/最大化/关闭）仅供 Windows：
    // macOS 由系统提供原生红绿灯与拖拽，不渲染 Windows 风格按钮
    // Flag-1050：自绘标题栏可被远程静默下线（下线后由系统原生标题栏接管）
    if (!Platform.isWindows ||
        !featureEnabled(FeatureGateService.flag1050TitleBar)) {
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
      case NavDestination.forwarders:
        return const NotificationForwardersPage();
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
    if (_versionTapCount >= 5) {
      _versionTapCount = 0;
      _showDeveloperUnlockDialog();
    }
  }

  void _showDeveloperUnlockDialog() {
    final api = ApiClient();
    showDialog(
      context: context,
      builder: (ctx) => DeveloperLoginDialog(api: api),
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
                    onCompleted: () {
                      setState(() => _welcomePhase = 'main');
                      // 欢迎流程中若静默检查已发现更新/预发行，进入主界面后补弹
                      _onAutoUpdateFound();
                      _onPreReleaseFound();
                    },
                  )
                : Row(
                    children: [
                      // Flag-1051：左侧导航栏可被远程静默下线。
                      // 下线后内容区占满整窗，当前页面保持不变。
                      if (featureEnabled(FeatureGateService.flag1051SideNav))
                        Material(
                          elevation: 0,
                          // 侧栏用固定色块与右侧内容区拉开色差（浅色偏冷的灰蓝，
                          // 深色更深一档），不再靠分割线区分
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF131C29)
                              : const Color(0xFFE9EFF7),
                          child: SizedBox(
                            width: 132,
                            child: Column(
                              children: [
                                const SizedBox(height: 40),
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 2,
                                    bottom: 12,
                                  ),
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
                                // 导航组上下留白按 1:2 分配：上方窄、下方宽，
                                // 整组相对几何中心上移约一个条目的高度（≈60），
                                // 视觉重心才落在侧栏正中
                                const Spacer(flex: 1),
                                ...NavDestination.values.map((dest) {
                                  final selected = _currentDest == dest;
                                  return _NavItem(
                                    icon: dest.icon,
                                    label: dest.label,
                                    selected: selected,
                                    onTap: () =>
                                        setState(() => _currentDest = dest),
                                  );
                                }),
                                const Spacer(flex: 2),
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: 16,
                                    top: 8,
                                  ),
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
                      Expanded(child: _buildPage(_currentDest)),
                    ],
                  ),
          ),
        ],
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
