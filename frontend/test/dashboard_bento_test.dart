import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grademonitor/core/network/api_client.dart';
import 'package:grademonitor/core/network/websocket_service.dart';
import 'package:grademonitor/core/theme/app_theme.dart';
import 'package:grademonitor/providers/grades_provider.dart';
import 'package:grademonitor/providers/monitor_provider.dart';
import 'package:grademonitor/providers/settings_provider.dart';
import 'package:grademonitor/views/dashboard/dashboard_page.dart';

/// 不真正建连：真实 WebSocketService 在测试环境连不上后端，
/// 失败后会用 Timer 反复排重连，留下 pending timer 让测试报错。
class _SilentWebSocketService extends WebSocketService {
  @override
  void connect() {}
}

class _FakeMonitor extends MonitorNotifier {
  _FakeMonitor(MonitorStatus status) : super(ApiClient()) {
    state = status;
  }
  @override
  Future<void> fetchStatus() async {}
}

class _FakeRank extends RankNotifier {
  _FakeRank(RankData? data) : super(ApiClient()) {
    state = AsyncValue.data(data);
  }
  @override
  Future<void> fetchRank() async {}
}

class _FakeGrades extends GradesNotifier {
  _FakeGrades() : super(ApiClient()) {
    state = const AsyncValue.data([]);
  }
  @override
  Future<void> fetchGrades() async {}
}

class _FakeSettings extends SettingsNotifier {
  _FakeSettings() : super(ApiClient());
  @override
  Future<void> fetchSettings() async {}
}

/// 只回 `/api/grades/latest-change`，其余一律 404。
/// Dashboard 首帧会拉这条接口，不回包会走异常分支。
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('latest-change')) {
      return ResponseBody.fromString(
        jsonEncode({'change': null}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

const _rank = RankData(
  pjxfjd: '3.72',
  bjpm: '12',
  pm: '48',
  countnum: '36',
  bjgms: '40',
);

Future<void> _pumpDashboard(WidgetTester tester, Size size) async {
  final api = ApiClient();
  api.dio.httpClientAdapter = _StubAdapter();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        webSocketProvider.overrideWithValue(_SilentWebSocketService()),
        monitorProvider.overrideWith(
          (ref) => _FakeMonitor(const MonitorStatus(totalQueries: 128)),
        ),
        rankProvider.overrideWith((ref) => _FakeRank(_rank)),
        gradesProvider.overrideWith((ref) => _FakeGrades()),
        settingsProvider.overrideWith((ref) => _FakeSettings()),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DashboardPage(),
      ),
    ),
  );
  // 首帧后 _initLoad 的微任务链需要推进；用固定时长而不是 pumpAndSettle，
  // 避免后端不可用时的重试定时器让 settle 永远等不到静止。
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 五张统计卡的 Material 容器，按渲染顺序（GPA→班排→专排→修读→次数）
List<Rect> _cardRects(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (w) =>
        w is Material &&
        w.borderRadius is BorderRadius &&
        w.color != null &&
        (w.borderRadius! as BorderRadius).topLeft.x <= AppShape.cornerHero &&
        w.clipBehavior == Clip.antiAlias,
  );
  return finder.evaluate().map((e) {
    final box = e.renderObject! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }).toList();
}

/// 只取统计卡那五张：按 y 排序后分成两行
List<List<Rect>> _rows(List<Rect> rects) {
  final sorted = [...rects]..sort((a, b) => a.top.compareTo(b.top));
  final rows = <List<Rect>>[];
  for (final r in sorted) {
    if (rows.isEmpty || (r.top - rows.last.first.top).abs() > 1) {
      rows.add([r]);
    } else {
      rows.last.add(r);
    }
  }
  for (final row in rows) {
    row.sort((a, b) => a.left.compareTo(b.left));
  }
  return rows;
}

BorderRadius _radiusOf(WidgetTester tester, Rect target) {
  final finder = find.byWidgetPredicate(
    (w) =>
        w is Material &&
        w.borderRadius is BorderRadius &&
        w.color != null &&
        w.clipBehavior == Clip.antiAlias,
  );
  for (final e in finder.evaluate()) {
    final box = e.renderObject! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if ((rect.top - target.top).abs() < .01 &&
        (rect.left - target.left).abs() < .01) {
      return (e.widget as Material).borderRadius! as BorderRadius;
    }
  }
  throw StateError('找不到卡片: $target');
}

void main() {
  testWidgets('第一行三等分、第二行二等分、两行左右边界对齐', (tester) async {
    await _pumpDashboard(tester, const Size(1100, 1400));

    final rows = _rows(_cardRects(tester));
    expect(rows.length, 2, reason: '上三下二两行');
    expect(rows[0].length, 3);
    expect(rows[1].length, 2);

    // 三等分：宽度两两相差不超过 0.01（Expanded 的 flex 全为 1）
    final top = rows[0];
    expect(top[0].width, closeTo(top[1].width, .01));
    expect(top[1].width, closeTo(top[2].width, .01));
    // 二等分
    final bottom = rows[1];
    expect(bottom[0].width, closeTo(bottom[1].width, .01));

    // 两行左右边界严格对齐
    expect(top.first.left, closeTo(bottom.first.left, .01));
    expect(top.last.right, closeTo(bottom.last.right, .01));

    // 间距统一 4px：行内水平缝隙 + 行间垂直缝隙
    expect(top[1].left - top[0].right, closeTo(4, .01));
    expect(top[2].left - top[1].right, closeTo(4, .01));
    expect(bottom[1].left - bottom[0].right, closeTo(4, .01));
    expect(bottom.first.top - top.first.bottom, closeTo(4, .01));

    expect(tester.takeException(), isNull);
  });

  testWidgets('只有组合外侧四角是 cornerHero，其余全部 cornerSmall', (tester) async {
    await _pumpDashboard(tester, const Size(1100, 1400));

    final rows = _rows(_cardRects(tester));
    final gpa = rows[0][0];
    final topMid = rows[0][1];
    final topRight = rows[0][2];
    final bottomLeft = rows[1][0];
    final bottomRight = rows[1][1];

    final gpaR = _radiusOf(tester, gpa);
    expect(gpaR.topLeft.x, AppShape.cornerHero);
    expect(gpaR.topRight.x, AppShape.cornerSmall);
    expect(gpaR.bottomLeft.x, AppShape.cornerSmall);
    expect(gpaR.bottomRight.x, AppShape.cornerSmall);

    // 上中：四角全 8
    final midR = _radiusOf(tester, topMid);
    expect(midR.topLeft.x, AppShape.cornerSmall);
    expect(midR.topRight.x, AppShape.cornerSmall);
    expect(midR.bottomLeft.x, AppShape.cornerSmall);
    expect(midR.bottomRight.x, AppShape.cornerSmall);

    // 右上：只有右上角是大圆角
    final trR = _radiusOf(tester, topRight);
    expect(trR.topLeft.x, AppShape.cornerSmall);
    expect(trR.topRight.x, AppShape.cornerHero);
    expect(trR.bottomLeft.x, AppShape.cornerSmall);
    expect(trR.bottomRight.x, AppShape.cornerSmall);

    // 左下：只有左下角是大圆角
    final blR = _radiusOf(tester, bottomLeft);
    expect(blR.topLeft.x, AppShape.cornerSmall);
    expect(blR.topRight.x, AppShape.cornerSmall);
    expect(blR.bottomLeft.x, AppShape.cornerHero);
    expect(blR.bottomRight.x, AppShape.cornerSmall);

    // 右下：只有右下角是大圆角
    final brR = _radiusOf(tester, bottomRight);
    expect(brR.topLeft.x, AppShape.cornerSmall);
    expect(brR.topRight.x, AppShape.cornerSmall);
    expect(brR.bottomLeft.x, AppShape.cornerSmall);
    expect(brR.bottomRight.x, AppShape.cornerHero);

    expect(tester.takeException(), isNull);
  });

  testWidgets('五张卡共用同一个背景 Token，且等于 surfaceContainerHighest', (tester) async {
    await _pumpDashboard(tester, const Size(1100, 1400));

    final expected = AppTheme.lightTheme.colorScheme.surfaceContainerHighest;
    final finder = find.byWidgetPredicate(
      (w) =>
          w is Material &&
          w.borderRadius is BorderRadius &&
          w.clipBehavior == Clip.antiAlias &&
          w.color != null,
    );
    final colors = finder
        .evaluate()
        .map((e) => (e.widget as Material).color)
        .toList();
    expect(colors.length, 5);
    for (final c in colors) {
      expect(c, expected);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('统计数字是卡片里的视觉焦点，且无溢出裁切', (tester) async {
    await _pumpDashboard(tester, const Size(1100, 1400));

    // GPA 数字（含小数部分）被拆成多个 TextSpan，找最大的那一段
    final numbers = <double>[];
    for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
      final span = w.text;
      span.visitChildren((s) {
        if (s is TextSpan && (s.text ?? '').isNotEmpty) {
          final size = s.style?.fontSize;
          if (size != null && size >= 26) numbers.add(size);
        }
        return true;
      });
    }
    expect(numbers, isNotEmpty);
    // 布局在默认 1100×720 窗口内不滚动的前提下，GPA 设计字号为 76；
    // 只要明显大于卡片标题（15）就算成立，不再绑定旧版的 104。
    expect(numbers.reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(60));

    // 卡片内容不得溢出（RenderFlex overflow 会进 takeException）
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口下不溢出，卡片仍保持两行结构', (tester) async {
    await _pumpDashboard(tester, const Size(700, 1200));

    final rows = _rows(_cardRects(tester));
    expect(rows.length, 2);
    expect(rows[0].length, 3);
    expect(rows[1].length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色模式下同样渲染正常', (tester) async {
    final api = ApiClient();
    api.dio.httpClientAdapter = _StubAdapter();
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          webSocketProvider.overrideWithValue(_SilentWebSocketService()),
          monitorProvider.overrideWith(
            (ref) => _FakeMonitor(const MonitorStatus(totalQueries: 128)),
          ),
          rankProvider.overrideWith((ref) => _FakeRank(_rank)),
          gradesProvider.overrideWith((ref) => _FakeGrades()),
          settingsProvider.overrideWith((ref) => _FakeSettings()),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const DashboardPage(),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final rows = _rows(_cardRects(tester));
    expect(rows.length, 2);
    final expected = AppTheme.darkTheme.colorScheme.surfaceContainerHighest;
    expect(_radiusOf(tester, rows[0][0]).topLeft.x, AppShape.cornerHero);
    expect(tester.takeException(), isNull);
    expect(expected, isNotNull);
  });
}
