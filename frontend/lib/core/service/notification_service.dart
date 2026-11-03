import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../logger/app_logger.dart';

/// macOS 原生通知服务
///
/// 重要性（2026-11 修复）：这是 macOS 上**首选的通知投递通道**。
/// 后端不再直接调用 `osascript display notification` —— 那条路径的通知由
/// osascript/Script Editor 代发，因此图标永远是系统通用占位图，点击也
/// 不会回到 App。改由本服务（App 自身进程，UNUserNotification）投递后：
///   · 通知图标 = 本 App 的 CFBundleIconName 图标
///   · 点击通知 = 激活本 App 并显示主窗口（见 main.dart 的响应处理）
///
/// 可靠性兜底：若原生插件初始化失败或投递异常，会回退到 `osascript`
/// （图标虽不理想，但提醒不会丢）。
///
/// 后端生成的通知**内容**（标题/正文/触发条件/去重）完全不变，仅改投递方。
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final _log = AppLogger('notification');
  FlutterLocalNotificationsPlugin? _plugin;
  bool _initialized = false;

  /// 点击通知时执行（由 main.dart 注入：显示并激活主窗口）
  static void Function()? onNotificationTap;

  Future<void> init() async {
    if (_initialized) return;
    if (!Platform.isMacOS) {
      _log.info('非 macOS 平台，跳过前端通知初始化（由后端负责系统通知）');
      return;
    }
    try {
      _plugin = FlutterLocalNotificationsPlugin();

      // 权限已在 AppDelegate 请求过，这里不重复弹窗
      const macOSSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );

      const initSettings = InitializationSettings(macOS: macOSSettings);

      await _plugin!.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onSelect,
      );
      _initialized = true;
      _log.info('通知服务初始化成功（原生通道，图标=App 图标）');
    } catch (e, stack) {
      _log.error('通知服务初始化失败，将回退 osascript', e, stack);
      _initialized = false;
    }
  }

  void _onSelect(NotificationResponse response) {
    _log.info('用户点击了通知 (payload=${response.payload})，尝试激活主窗口');
    try {
      onNotificationTap?.call();
    } catch (e) {
      _log.warning('通知点击回调执行失败: $e');
    }
  }

  /// 显示 macOS 原生通知；原生不可用时回退 osascript。
  Future<void> show(String title, String message) async {
    if (!Platform.isMacOS) {
      _log.warning('非 macOS 平台，跳过前端通知: $title');
      return;
    }

    if (_initialized && _plugin != null) {
      try {
        await _plugin!.show(
          0, // id 固定为 0，每次覆盖上一条
          title,
          message,
          const NotificationDetails(
            macOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBanner: true,
              presentList: true,
              presentBadge: false,
              presentSound: true,
              // 同一类通知归入 App 的通知线程，便于系统聚焦/分组
              threadIdentifier: 'GradeMonitor',
            ),
          ),
        );
        _log.info('通知已发送（原生通道）: $title');
        return;
      } catch (e, stack) {
        _log.error('原生通知发送失败，回退 osascript: $title', e, stack);
      }
    } else {
      _log.warning('通知服务未初始化，回退 osascript: $title');
    }

    await _fallbackOsascript(title, message);
  }

  /// 兜底：osascript（图标为系统占位图，但保证提醒可达）
  Future<void> _fallbackOsascript(String title, String message) async {
    try {
      final t = title.replaceAll('"', '\\"');
      final m = message.replaceAll('"', '\\"');
      await Process.run('osascript', [
        '-e',
        'display notification "$m" with title "$t"',
      ]);
      _log.info('通知已发送（osascript 兜底）: $title');
    } catch (e) {
      _log.error('osascript 兜底也失败: $title', e);
    }
  }
}
