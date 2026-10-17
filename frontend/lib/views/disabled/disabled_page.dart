import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/service/update_service.dart';

/// 程序禁用页：远程停用开关 / 防滥用检测命中时由 main.dart 切换显示
class DisabledScreen extends StatefulWidget {
  const DisabledScreen({super.key});

  @override
  State<DisabledScreen> createState() => _DisabledScreenState();
}

class _DisabledScreenState extends State<DisabledScreen> {
  /// 整页背景色（深红），所有文字白色系
  static const Color _bgColor = Color(0xFFAE0B2A);

  /// 事件时间：页面出现时刻
  late final String _eventTime = _formatEventTime(DateTime.now());

  final TapGestureRecognizer _githubRecognizer = TapGestureRecognizer();
  final TapGestureRecognizer _versionRecognizer = TapGestureRecognizer();

  // 隐秘后门：900ms 内连续点击 3 次"版本号"解除禁用
  int _secretTaps = 0;
  Timer? _secretTimer;

  @override
  void initState() {
    super.initState();
    _githubRecognizer.onTap = () => UpdateService().openInBrowser();
    _versionRecognizer.onTap = _onSecretTap;
  }

  @override
  void dispose() {
    _githubRecognizer.dispose();
    _versionRecognizer.dispose();
    _secretTimer?.cancel();
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 格式：GMT+8 YYYY:MM:DD_HH:MM:SS
  static String _formatEventTime(DateTime t) =>
      'GMT+8 ${t.year}:${_two(t.month)}:${_two(t.day)}'
      '_${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  void _onSecretTap() {
    _secretTaps++;
    _secretTimer?.cancel();
    _secretTimer = Timer(const Duration(milliseconds: 900), () {
      _secretTaps = 0;
    });
    if (_secretTaps < 3) return;
    _secretTimer?.cancel();
    _secretTaps = 0;
    // 解除禁用：main.dart 监听后自动切回主页，程序不退出
    UpdateService.disabled.value = false;
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _confirmExit() async {
    try {
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  Widget _reason(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          height: 1.6,
          color: Colors.white.withValues(alpha: .92),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final version = UpdateService().currentVersion;
    final versionText = version.isEmpty ? '…' : version;

    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 48,
                      vertical: 40,
                    ),
                    // 内容块整体水平居中，文字左对齐
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 113,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 32),
                        const Text(
                          '程序已禁用',
                          style: TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          '当前程序副本因为下述中的一个或几个原因已被停用。'
                          '您可以通过 Github 的 issue 功能提交反馈。',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.6,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _reason('1. 违反有关主管单位的规定，由开发者主动停用。'),
                        _reason('2. 您设置的请求次数过于频繁，对服务器造成负担过重。'),
                        _reason('3. 当前版本已过期，需要检查并安装更新。'),
                        _reason('4. 误触了仅开发者可使用的功能。'),
                        _reason('5. 程序文件损坏或意外丢失。'),
                        const SizedBox(height: 44),
                        FilledButton(
                          onPressed: _confirmExit,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: _bgColor,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 52,
                              vertical: 18,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '好',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 底部信息行
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 48, 18),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: .75),
                  ),
                  children: [
                    // 隐秘后门触发区：仅"版本号"三个字（不含冒号和数字），
                    // 无任何视觉/触觉反馈，与普通文字完全一致
                    TextSpan(text: '版本号', recognizer: _versionRecognizer),
                    TextSpan(text: '：$versionText    事件时间：$_eventTime    '),
                    TextSpan(
                      text: 'Github',
                      style: const TextStyle(
                        color: Colors.white,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: _githubRecognizer,
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
