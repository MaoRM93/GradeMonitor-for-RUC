import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../logger/app_logger.dart';

/// macOS 原生通知服务
///
/// 说明：系统通知的实际发送由后端负责（macOS 走 osascript，Windows 走
/// win11toast）。本服务仅作为 macOS 侧的辅助通道（WebSocket show_notification
/// 事件触发），当前 flutter_local_notifications v18 不支持 Windows，因此在
/// Windows 上直接跳过初始化，避免 macOS 专属代码误执行。
///
/// 不负责成绩逻辑、通知内容生成。
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final _log = AppLogger('notification');
  FlutterLocalNotificationsPlugin? _plugin;
  bool _initialized = false;

  /// 初始化通知插件（仅初始化一次）
  Future<void> init() async {
    if (_initialized) return;
    if (!Platform.isMacOS) {
      _log.info('非 macOS 平台，跳过前端通知初始化（由后端负责系统通知）');
      return;
    }
    try {
      _plugin = FlutterLocalNotificationsPlugin();

      // macOS 初始化设置
      const macOSSettings = DarwinInitializationSettings(
        requestAlertPermission: false, // 权限已在 AppDelegate 中请求
        requestBadgePermission: false,
        requestSoundPermission: false,
      );

      const initSettings = InitializationSettings(macOS: macOSSettings);

      await _plugin!.initialize(initSettings);
      _initialized = true;
      _log.info('通知服务初始化成功');
    } catch (e, stack) {
      _log.error('通知服务初始化失败（App 仍可正常运行）', e, stack);
      _initialized = false;
    }
  }

  /// 显示 macOS 原生通知
  void show(String title, String message) {
    if (!Platform.isMacOS) {
      _log.warning('非 macOS 平台，跳过前端通知: $title');
      return;
    }
    if (!_initialized || _plugin == null) {
      _log.warning('通知服务未初始化，跳过通知: $title');
      return;
    }

    try {
      _plugin!.show(
        0, // id 固定为 0，每次覆盖上一条
        title,
        message,
        const NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: true,
          ),
        ),
      );
      _log.info('通知已发送: $title');
    } catch (e, stack) {
      _log.error('发送通知失败: $title', e, stack);
    }
  }
}
