import 'dart:io';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../logger/app_logger.dart';
import 'backend_service.dart';

/// 系统托盘（菜单栏图标）服务
///
/// 提供托盘初始化、销毁、事件处理，供 main.dart 和设置页共用。
class TrayService {
  static final TrayService _instance = TrayService._();
  factory TrayService() => _instance;
  TrayService._();

  final _log = AppLogger('tray_svc');
  bool _initialized = false;

  /// 初始化系统托盘
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      // setIcon 内部会自动拼接 <exeDir>/data/flutter_assets/ 前缀，
      // 因此必须传相对 assets 的路径，不能传绝对路径（否则托盘图标失效、
      // 右键菜单也不可用）。Windows 托盘对 PNG 支持不稳，优先用 ICO。
      final String iconPath =
          Platform.isWindows ? 'assets/app_icon.ico' : 'assets/tray_icon.png';

      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('GradeMonitor');

      final menu = Menu(
        items: [
          MenuItem(key: 'show', label: '开启主界面'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出程序'),
        ],
      );
      await trayManager.setContextMenu(menu);

      trayManager.addListener(_TrayHandler(_log));
      _log.info('系统托盘已初始化（图标 + 右键菜单）');
    } catch (e) {
      _initialized = false;
      _log.warning('系统托盘初始化失败: $e');
    }
  }

  /// 销毁系统托盘
  Future<void> destroy() async {
    if (!_initialized) return;
    try {
      await trayManager.destroy();
    } catch (_) {}
    _initialized = false;
    _log.info('系统托盘已销毁');
  }

  bool get initialized => _initialized;

  Future<void> _quitApp() async {
    _log.info('退出程序');
    await BackendService().stop();
    await trayManager.destroy();
    exit(0);
  }
}

class _TrayHandler implements TrayListener {
  final AppLogger _log;
  _TrayHandler(this._log);

  @override
  void onTrayIconMouseDown() {
    // 左键也弹菜单：用户只需要右键菜单，不需要左键直接显示主界面
    trayManager.popUpContextMenu();
    _log.info('托盘图标左键点击 -> 弹出菜单');
  }

  @override
  void onTrayIconMouseUp() {}

  @override
  void onTrayIconRightMouseDown() {
    // Windows 原生端右键抬起只回调本方法，需手动调用 popUpContextMenu 弹出菜单
    trayManager.popUpContextMenu();
    _log.info('托盘图标右键点击 -> 弹出菜单');
  }

  @override
  void onTrayIconRightMouseUp() {}

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      windowManager.show();
      windowManager.focus();
      _log.info('托盘菜单: 显示主窗口');
    } else if (menuItem.key == 'quit') {
      _log.info('退出程序');
      BackendService().stop();
      trayManager.destroy();
      exit(0);
    }
  }
}
