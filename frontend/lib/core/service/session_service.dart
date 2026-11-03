import 'package:flutter/foundation.dart';

/// 会话状态广播。
///
/// 设置页点「退出登录」后，需要让导航层立刻把界面切回欢迎向导重新登录。
/// 设置页与导航层之间隔着多层 Page，用全局 ValueNotifier 广播比层层透传回调干净。
class SessionService {
  SessionService._();

  /// 每次退出登录时自增。用计数器而非 bool，保证连续多次退出都能触发。
  static final ValueNotifier<int> logoutSignal = ValueNotifier<int>(0);

  /// 广播一次「已退出登录」
  static void notifyLogout() {
    logoutSignal.value++;
  }
}
