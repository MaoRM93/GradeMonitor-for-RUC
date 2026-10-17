import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'core/theme/app_theme.dart';
import 'core/logger/app_logger.dart';
import 'core/service/backend_service.dart';
import 'core/service/tray_service.dart';
import 'core/service/notification_service.dart';
import 'core/network/websocket_service.dart';
import 'views/navigation/app_navigation.dart';
import 'views/disabled/disabled_page.dart';
import 'core/service/update_service.dart';
import 'widgets/toast_host.dart';

/// 全局 WebSocket — 用于通知监听，独立于 UI 生命周期
final _globalWs = WebSocketService();

/// 全局导航器 — 更新弹窗与全局 Toast 等无 BuildContext 场景使用
final navigatorKey = toastNavigatorKey;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppLogger.init(minLevel: LogLevel.debug);
  final log = AppLogger('main');

  // 全局错误捕获：写入日志文件，避免 debug 断言错误只闪现在终端无法回溯
  FlutterError.onError = (details) {
    log.error(
      'FlutterError: ${details.exception}',
      details.exception,
      details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('未捕获异常: $error', error, stack);
    return true;
  };

  // 初始化更新服务：读取完整版本号 + 静默检查远程停用开关
  await UpdateService().init();

  await BackendService().start();

  // 初始化通知服务（失败不影响 App 运行）
  await NotificationService().init();

  // 全局 WebSocket 通知监听（独立于任何页面生命周期）
  _globalWs.connect();
  _globalWs.eventStream.listen((event) {
    if (event.type == WsEventType.showNotification) {
      final title = event.data['title'] as String? ?? '';
      final message = event.data['message'] as String? ?? '';
      NotificationService().show(title, message);
    }
  });

  await windowManager.ensureInitialized();

  // 必须在 main() 中、ensureInitialized 之后立即调用，
  // 确保原生层在窗口创建前就注册好关闭拦截
  await windowManager.setPreventClose(true);

  // 恢复 waitUntilReadyToShow，确保 NSWindowDelegate 正确挂载，
  // 使 WindowListener.onWindowClose 能被触发
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: 'GradeMonitor',
      size: const Size(1100, 720),
      minimumSize: const Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
    ),
    // 回调中不调用 show()，等首帧渲染后再显示，避免黑屏
    () async {},
  );

  // 根据设置决定是否初始化托盘图标
  if (await _shouldShowTray(log)) {
    await TrayService().init();
  }

  runApp(const ProviderScope(child: GradeMonitorApp()));

  // 等待首帧渲染完毕再显示窗口，彻底避免黑屏闪烁
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await windowManager.show();
  await windowManager.focus();
  log.info('窗口已显示');
}

/// 从后端读取设置，决定是否显示托盘图标
Future<bool> _shouldShowTray(AppLogger log) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    final request = await client.get('127.0.0.1', 18923, '/api/settings');
    final response = await request.close();
    if (response.statusCode == 200) {
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;
      client.close();
      final show = data['show_menubar_icon'] ?? true;
      log.info('托盘图标设置: $show');
      return show;
    }
    client.close();
  } catch (e) {
    log.warning('读取托盘设置失败，默认开启: $e');
  }
  return true; // 默认显示托盘
}

class GradeMonitorApp extends StatefulWidget {
  const GradeMonitorApp({super.key});

  @override
  State<GradeMonitorApp> createState() => _GradeMonitorAppState();
}

class _GradeMonitorAppState extends State<GradeMonitorApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    BackendService().stop();
    super.dispose();
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GradeMonitor',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      // 禁用开关生效时切换显示 DisabledScreen 替代 AppNavigation
      home: ValueListenableBuilder<bool>(
        valueListenable: UpdateService.disabled,
        builder: (context, isDisabled, child) {
          return isDisabled ? const DisabledScreen() : const AppNavigation();
        },
      ),
    );
  }
}
