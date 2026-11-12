import 'package:flutter/foundation.dart';

/// 跨页面导航请求（例：仪表板「查看完整成绩 →」跳转到成绩单页）。
/// AppNavigation 监听 [navRequest]，收到后切换当前目的地。
enum AppNavTarget { dashboard, grades, scheme, settings }

/// 当前待处理的导航请求；AppNavigation 消费后会置回 null。
final ValueNotifier<AppNavTarget?> navRequest = ValueNotifier<AppNavTarget?>(null);

/// 请求切换到某个页面。先置 null 再置目标，保证同一目标连续点击也能触发。
void requestNav(AppNavTarget target) {
  navRequest.value = null;
  navRequest.value = target;
}
