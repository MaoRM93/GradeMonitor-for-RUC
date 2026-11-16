import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grademonitor/core/network/websocket_service.dart';
import 'package:grademonitor/core/service/update_service.dart';
import 'package:grademonitor/main.dart';
import 'package:grademonitor/providers/monitor_provider.dart';

/// 测试替身：不真正建连。
///
/// 真实 [WebSocketService] 在测试环境连不上后端（TestWidgetsFlutterBinding
/// 把所有 HTTP/WS 请求拦成 400），失败后会用 `Timer` 反复排重连；那些
/// 定时器挂在单例上、不随 widget 树销毁，会让测试报 pending timer。
class _SilentWebSocketService extends WebSocketService {
  @override
  void connect() {}
}

void main() {
  testWidgets('App renders without error', (WidgetTester tester) async {
    // UpdateService 是进程级单例，init() 建立的周期定时器（1 小时更新检查、
    // 30 秒滥用轮询）不随 widget 树销毁，收尾统一取消，避免测试间泄漏。
    addTearDown(UpdateService().cancelTimers);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          webSocketProvider.overrideWithValue(_SilentWebSocketService()),
        ],
        child: const GradeMonitorApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 欢迎页状态检查在后端不可用时会按 500ms 重试 20 次（共 10s）。
    // 逐段推进假时钟把这条重试链走完，否则它会在树销毁后留下 pending 的
    // 延迟定时器。按 500ms 步进，对 maxRetries 的调整保持宽容。
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('GradeMonitor'), findsNothing);
  });
}
