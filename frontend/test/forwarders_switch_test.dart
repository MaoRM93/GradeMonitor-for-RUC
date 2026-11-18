import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grademonitor/core/network/api_client.dart';
import 'package:grademonitor/core/theme/app_theme.dart';
import 'package:grademonitor/views/forwarders/notification_forwarders_page.dart';
import 'package:grademonitor/widgets/expressive_switch.dart';

/// 记录请求体并按后端语义回包的假适配器。
///
/// 后端 `save_config` 只在字段出现时覆盖，所以这里也按「合并」实现，才能验证
/// 「保存只存凭据、开关才改 enabled」这条边界没有被前端自己绕过。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.state);

  final Map<String, Map<String, dynamic>> state;
  final List<Map<String, dynamic>> posts = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode(state),
        200,
        headers: _jsonHeaders,
      );
    }
    final body = jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>;
    posts.add(body);
    body.forEach((channel, value) {
      final entry = state[channel];
      if (entry == null || value is! Map) return;
      value.forEach((key, v) {
        if (key == 'url' || key == 'nickname' || key == 'topic') {
          if (v == '') return;
        }
        entry[key] = v;
      });
    });
    final forwarders = {
      for (final e in state.entries)
        e.key: {
          'enabled': e.value['enabled'] == true,
          'configured': switch (e.key) {
            'bark' => (e.value['url'] ?? '') != '',
            'meow' => (e.value['nickname'] ?? '') != '',
            _ => (e.value['topic'] ?? '') != '',
          },
          if (e.key == 'ntfy') 'server': e.value['server'] ?? 'https://ntfy.sh',
        },
    };
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'forwarders': forwarders}),
      200,
      headers: _jsonHeaders,
    );
  }

  static const _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  void close({bool force = false}) {}
}

Map<String, Map<String, dynamic>> _initialState() => {
  'bark': {'enabled': false, 'url': 'https://api.day.app/OLD'},
  'meow': {'enabled': false, 'nickname': ''},
  'ntfy': {
    'enabled': false,
    'server': 'https://ntfy.sh',
    'topic': 'grade_topic',
  },
};

Future<_RecordingAdapter> _pumpPage(WidgetTester tester) async {
  final state = _initialState();
  final adapter = _RecordingAdapter(state);
  final api = ApiClient();
  api.dio.httpClientAdapter = adapter;
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: const NotificationForwardersPage(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
  return adapter;
}

void main() {
  testWidgets('保存按钮只提交凭据，不携带 enabled', (tester) async {
    final adapter = await _pumpPage(tester);
    adapter.posts.clear();

    await tester.enterText(find.byType(TextField).first, 'https://api.day.app/NEW');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存此通道').first);
    await tester.pump(const Duration(milliseconds: 200));

    expect(adapter.posts, isNotEmpty);
    final body = adapter.posts.last;
    expect(body.keys, contains('bark'));
    expect(
      (body['bark'] as Map).containsKey('enabled'),
      isFalse,
      reason: '保存不应改变开关状态',
    );
    expect(adapter.state['bark']!['enabled'], isFalse);
    expect(adapter.state['bark']!['url'], 'https://api.day.app/NEW');
  });

  testWidgets('点击开关立即落盘，无需再点保存', (tester) async {
    final adapter = await _pumpPage(tester);
    adapter.posts.clear();

    // 先在输入框里改成新地址，验证开关会把「当前输入」一起提交，
    // 而不是只翻转 enabled、把旧地址留给后端。
    await tester.enterText(
      find.byType(TextField).first,
      'https://api.day.app/TOGGLE',
    );
    await tester.pump();

    // 第一个 ExpressiveSwitch 是 Bark 卡片右上角的开关。
    await tester.tap(find.byType(ExpressiveSwitch).first);
    await tester.pump(const Duration(milliseconds: 400));

    expect(adapter.posts, isNotEmpty);
    final body = adapter.posts.last;
    expect((body['bark'] as Map)['enabled'], isTrue);
    expect(adapter.state['bark']!['enabled'], isTrue);
    expect(adapter.state['bark']!['url'], 'https://api.day.app/TOGGLE');
  });

  testWidgets('未配置的通道点开关不会开启转发', (tester) async {
    final adapter = await _pumpPage(tester);
    adapter.posts.clear();

    // 第二个开关是 Meow，昵称为空。
    await tester.tap(find.byType(ExpressiveSwitch).at(1));
    await tester.pump(const Duration(milliseconds: 400));

    expect(adapter.posts, isEmpty);
    expect(adapter.state['meow']!['enabled'], isFalse);
  });
}
