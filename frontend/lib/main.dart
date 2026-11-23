import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'core/theme/app_theme.dart';
import 'core/logger/app_logger.dart';
import 'core/constants/api_token.dart';
import 'core/service/backend_service.dart';
import 'core/service/feature_gate_service.dart';
import 'core/service/tray_service.dart';
import 'core/service/notification_service.dart';
import 'core/network/websocket_service.dart';
import 'views/navigation/app_navigation.dart';
import 'views/disabled/disabled_page.dart';
import 'views/disabled/developer_notice_page.dart';
import 'views/notice/broadcast_toast.dart';
import 'core/service/update_service.dart';
import 'widgets/toast_host.dart';
import 'widgets/window_controls.dart';

/// 全局 WebSocket — 用于通知监听，独立于 UI 生命周期
final _globalWs = WebSocketService();

/// 全局导航器 — 更新弹窗与全局 Toast 等无 BuildContext 场景使用
final navigatorKey = toastNavigatorKey;

const _launchChannel = MethodChannel('com.grademonitor.app/launch');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 主题在启动阶段先从本机偏好恢复，避免首帧显示默认蓝色后再跳变。
  await ThemeController.instance.load();

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

  await windowManager.ensureInitialized();

  // 必须在 main() 中、ensureInitialized 之后立即调用，
  // 确保原生层在窗口创建前就注册好关闭拦截
  await windowManager.setPreventClose(true);

  // 恢复 waitUntilReadyToShow，确保 NSWindowDelegate 正确挂载，
  // 使 WindowListener.onWindowClose 能被触发
  final windowSize = await _resolveInitialWindowSize(log);
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: 'GradeMonitor',
      size: windowSize.size,
      minimumSize: windowSize.minimum,
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
    ),
    // 回调中不调用 show()，等首帧渲染后再显示，避免黑屏
    () async {},
  );

  runApp(const ProviderScope(child: GradeMonitorApp()));

  // 首帧真正落盘前不显示原生主窗口，避免 Dock 重开路径出现黑窗口。
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  if (Platform.isMacOS) {
    try {
      await _launchChannel.invokeMethod<void>('firstFrameRendered');
    } on PlatformException catch (e) {
      log.warning('通知原生层首帧已就绪失败: $e');
    }
  }
  await windowManager.show();
  await windowManager.focus();
  log.info('窗口已显示');

  // 后端与远程服务可能等待进程或网络，不能阻塞首个界面。
  unawaited(_initializeBackgroundServices(log));
}

Future<void> _initializeBackgroundServices(AppLogger log) async {
  try {
    await UpdateService().init();
    await BackendService().start();
    await FeatureGateService.instance.ensureLoaded();
    final gates = FeatureGateService.instance;

    if (Platform.isWindows &&
        !gates.isEnabled(FeatureGateService.flag1050TitleBar)) {
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }

    await NotificationService().init();
    NotificationService.onNotificationTap = () async {
      if (!gates.isEnabled(FeatureGateService.flag1054NotificationTap)) return;
      try {
        if (!await windowManager.isVisible()) await windowManager.show();
        await windowManager.focus();
        log.info('通过通知点击激活主窗口');
      } catch (e) {
        log.warning('通知点击激活窗口失败: $e');
      }
    };

    if (gates.isEnabled(FeatureGateService.flag1074WebSocket)) {
      _globalWs.connect();
      _globalWs.eventStream.listen((event) {
        if (event.type == WsEventType.showNotification) {
          final title = event.data['title'] as String? ?? '';
          final message = event.data['message'] as String? ?? '';
          NotificationService().show(title, message);
        }
      });
    }

    if (gates.isEnabled(FeatureGateService.flag1052Tray) &&
        await _shouldShowTray(log)) {
      await TrayService().init();
    }
  } catch (e, stack) {
    log.error('后台服务初始化失败', e, stack);
  }
}

/// 初始窗口尺寸的计算结果。
///
/// 为什么需要它：Windows 上窗口尺寸是按**逻辑像素**解释的，而系统可能开着
/// 150% 之类的显示缩放。此时 1280x800 的物理屏只有 853x501 逻辑像素，
/// 写死的 1100x720 会让窗口比屏幕还大，底部内容被屏幕边缘裁掉——表现就是
/// "下面的窗口被截断"。因此必须把设计尺寸夹到显示器工作区内。
class _InitialWindowSize {
  const _InitialWindowSize(this.size, this.minimum);

  final Size size;
  final Size minimum;
}

/// 设计基准尺寸：这是布局调优时假定的窗口大小。
const Size _designWindowSize = Size(1100, 720);

/// 设计基准最小尺寸：低于此值布局会明显拥挤，但为了适配小屏仍需继续下探。
const Size _designMinimumSize = Size(900, 600);

/// 计算把窗口完整放进屏幕所需的初始尺寸与最小尺寸。
///
/// 取值规则：
/// - 优先使用显示器工作区（扣除任务栏），拿不到工作区时退回整屏尺寸；
/// - 宽高都夹到工作区内，并留出少量边距，避免窗口边缘压到任务栏或屏幕边缘；
/// - 最小尺寸同步下调，否则窗口管理器会拒绝收缩到比 minimumSize 更小。
Future<_InitialWindowSize> _resolveInitialWindowSize(AppLogger log) async {
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    // visibleSize 是工作区（不含任务栏），个别平台可能为空，退回整屏尺寸。
    final area = display.visibleSize ?? display.size;
    if (area.width <= 0 || area.height <= 0) {
      return const _InitialWindowSize(_designWindowSize, _designMinimumSize);
    }

    // 预留 24 逻辑像素边距，避免贴边。
    final maxW = area.width - 24;
    final maxH = area.height - 24;

    final width = _designWindowSize.width < maxW
        ? _designWindowSize.width
        : maxW;
    final height = _designWindowSize.height < maxH
        ? _designWindowSize.height
        : maxH;

    // 最小尺寸同样不得超过工作区，否则无法缩小到屏幕内。
    final minW = _designMinimumSize.width < width
        ? _designMinimumSize.width
        : width;
    final minH = _designMinimumSize.height < height
        ? _designMinimumSize.height
        : height;

    log.info(
      '显示器工作区 ${area.width.toInt()}x${area.height.toInt()}'
      '（缩放 ${display.scaleFactor ?? '-'}），'
      '初始窗口 ${width.toInt()}x${height.toInt()}，'
      '最小窗口 ${minW.toInt()}x${minH.toInt()}',
    );

    return _InitialWindowSize(
      Size(width.floorToDouble(), height.floorToDouble()),
      Size(minW.floorToDouble(), minH.floorToDouble()),
    );
  } catch (e) {
    // 拿不到显示器信息时退回设计尺寸，至少不比原来更差。
    log.warning('读取显示器尺寸失败，使用默认窗口尺寸: $e');
    return const _InitialWindowSize(_designWindowSize, _designMinimumSize);
  }
}

/// 从后端读取设置，决定是否显示托盘图标
Future<bool> _shouldShowTray(AppLogger log) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    final request = await client.get('127.0.0.1', 18923, '/api/settings');
    if (ApiToken.value.isNotEmpty) {
      request.headers.set(ApiToken.headerName, ApiToken.value);
    }
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
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final controller = ThemeController.instance;
        return MaterialApp(
          title: 'GradeMonitor',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: AppTheme.lightThemeFor(controller.preset),
          darkTheme: AppTheme.darkThemeFor(controller.preset),
          themeMode: controller.mode,
          themeAnimationDuration: const Duration(milliseconds: 280),
          themeAnimationCurve: Curves.easeInOutCubic,
          home: AnimatedBuilder(
            animation: Listenable.merge([
              UpdateService.disabled,
              UpdateService.releaseNotice,
            ]),
            builder: (context, child) {
              final notice = UpdateService.releaseNotice.value;
              if (UpdateService.disabled.value) {
                return DisabledScreen(
                  notice: notice?.kind == NoticeKind.killSwitch ? notice : null,
                );
              }
              if (notice != null && notice.kind == NoticeKind.developerNotice) {
                return DeveloperNoticeScreen(notice: notice);
              }
              // Windows 下右上角被悬浮三键胶囊占用（6+30px），
              // 广播浮层要下移避让；macOS 无自绘三键，保持原位置。
              final toastTop = Platform.isWindows
                  ? kWindowControlsReservedHeight + 12
                  : 30.0;
              return Stack(
                children: [
                  const AppNavigation(),
                  Positioned(
                    top: toastTop,
                    right: 26,
                    child: const BroadcastToast(),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
