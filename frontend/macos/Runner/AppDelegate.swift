import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate {
  private var flutterHasRenderedFirstFrame = false
  private var startupAttentionRequest: Int?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    configureLaunchChannel()
    requestStartupAttention()
    // FlutterViewController 在 viewWillAppear 启动引擎。先挂载透明窗口，
    // 让引擎开始绘制，等 Dart 确认首帧后再恢复可见性。
    mainFlutterWindow?.alphaValue = 0
    mainFlutterWindow?.orderFront(nil)

    // 请求 macOS 通知权限（仅一次，用户拒绝也不影响 App 运行）
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      if let error = error {
        NSLog("GradeMonitor: 通知权限请求失败: \(error.localizedDescription)")
      } else if granted {
        NSLog("GradeMonitor: 通知权限已授予")
      } else {
        NSLog("GradeMonitor: 用户拒绝了通知权限")
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      if flutterHasRenderedFirstFrame, let window = mainFlutterWindow {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
      } else {
        // Flutter 首帧完成前保持窗口隐藏，避免显示未绘制的黑色内容区。
        requestStartupAttention()
      }
    }
    return flutterHasRenderedFirstFrame
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func configureLaunchChannel() {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "com.grademonitor.app/launch",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "firstFrameRendered" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.flutterHasRenderedFirstFrame = true
      self?.mainFlutterWindow?.alphaValue = 1
      self?.finishStartupAttention()
      result(nil)
    }
  }

  private func requestStartupAttention() {
    NSApplication.shared.dockTile.badgeLabel = "…"
    if !NSApplication.shared.isActive, startupAttentionRequest == nil {
      startupAttentionRequest = NSApplication.shared.requestUserAttention(.informationalRequest)
    }
  }

  private func finishStartupAttention() {
    NSApplication.shared.dockTile.badgeLabel = nil
    if let request = startupAttentionRequest {
      NSApplication.shared.cancelUserAttentionRequest(request)
      startupAttentionRequest = nil
    }
  }
}
