import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/service/update_service.dart';

/// Release 正文为空时的兜底文案（禁用页 / 提醒页共用）
const String kReleaseBodyFallback = '本次更新说明为空，请前往 GitHub 发布页查看。';

/// 深色底 + 白字场景下的 Markdown 样式（标题/正文/列表/引用/代码/链接）
///
/// 底色为深色整屏，故全部文字用白色及其半透明层级；代码块/表格用
/// 白色低透明度填充，保证在红底与蓝底上都可读。
MarkdownStyleSheet releaseNoticeMarkdownStyle(BuildContext context) {
  const on = Colors.white;
  TextStyle base({FontWeight weight = FontWeight.w400, double size = 15}) =>
      TextStyle(
        fontSize: size,
        height: 1.65,
        fontWeight: weight,
        color: on.withValues(alpha: .96),
      );
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    a: base().copyWith(
      color: on,
      decoration: TextDecoration.underline,
      decorationColor: on.withValues(alpha: .7),
    ),
    p: base(),
    pPadding: const EdgeInsets.only(bottom: 4),
    h1: base(weight: FontWeight.w900, size: 26).copyWith(height: 1.4),
    h2: base(weight: FontWeight.w800, size: 22).copyWith(height: 1.4),
    h3: base(weight: FontWeight.w800, size: 19).copyWith(height: 1.4),
    h4: base(weight: FontWeight.w700, size: 17),
    h5: base(weight: FontWeight.w700, size: 16),
    h6: base(weight: FontWeight.w700, size: 15),
    strong: base(weight: FontWeight.w800).copyWith(color: on),
    em: base().copyWith(fontStyle: FontStyle.italic),
    del: base().copyWith(decoration: TextDecoration.lineThrough),
    listBullet: base(),
    listIndent: 22,
    blockSpacing: 10,
    blockquote: base().copyWith(color: on.withValues(alpha: .78)),
    blockquotePadding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
    blockquoteDecoration: BoxDecoration(
      color: on.withValues(alpha: .08),
      border: Border(
        left: BorderSide(color: on.withValues(alpha: .55), width: 3),
      ),
    ),
    code: TextStyle(
      fontSize: 13,
      height: 1.5,
      color: on.withValues(alpha: .95),
      fontFamily: 'monospace',
      backgroundColor: on.withValues(alpha: .12),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: on.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(10),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: on.withValues(alpha: .28))),
    ),
    tableHead: base(weight: FontWeight.w800, size: 14),
    tableBody: base(size: 14),
    tableBorder: TableBorder.all(color: on.withValues(alpha: .28)),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableHeadCellsDecoration: BoxDecoration(color: on.withValues(alpha: .14)),
    checkbox: base().copyWith(color: on.withValues(alpha: .9)),
  );
}

/// 全屏 Release 提示外壳：禁用页与开发者提醒页共用同一套位置与字号层级
///
/// 布局与旧禁用页保持一致：
/// Center → ConstrainedBox(maxWidth 640) → SingleChildScrollView(h48, v40)
/// → Column(start) → 图标(113) → 32 → 标题(40/w900) → 18 → 引导语
/// → 20 → Markdown 正文 → 44 → 按钮
///
/// 底部版本号 / 事件时间 / Github 一行固定在整屏底部，不随正文滚动。
class ReleaseNoticeScaffold extends StatefulWidget {
  /// 整屏底色（禁用页深红 / 提醒页深蓝）
  final Color bgColor;

  /// 顶部图标（禁用 = 警告三角，提醒 = 填充铃铛）
  final IconData icon;

  /// 主标题
  final String title;

  /// 标题与正文之间的引导语；为空则不渲染
  final String intro;

  /// Release body 的 Markdown 原文；为空时使用 [kReleaseBodyFallback]
  final String markdown;

  /// 正文下方的主按钮
  final Widget action;

  /// 可选：接管底栏「版本号」三个字的点击识别器（禁用页的隐秘后门用）。
  /// 传入后这三个字与普通文字外观完全一致，无任何额外反馈。
  final TapGestureRecognizer? versionLabelRecognizer;

  const ReleaseNoticeScaffold({
    super.key,
    required this.bgColor,
    required this.icon,
    required this.title,
    required this.markdown,
    required this.action,
    this.intro = '',
    this.versionLabelRecognizer,
  });

  @override
  State<ReleaseNoticeScaffold> createState() => _ReleaseNoticeScaffoldState();
}

class _ReleaseNoticeScaffoldState extends State<ReleaseNoticeScaffold> {
  /// 事件时间：页面出现时刻
  late final String _eventTime = _formatEventTime(DateTime.now());

  final TapGestureRecognizer _githubRecognizer = TapGestureRecognizer()
    ..onTap = () => UpdateService().openInBrowser();

  @override
  void dispose() {
    _githubRecognizer.dispose();
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 格式：GMT+8 YYYY:MM:DD_HH:MM:SS
  static String _formatEventTime(DateTime t) =>
      'GMT+8 ${t.year}:${_two(t.month)}:${_two(t.day)}'
      '_${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  @override
  Widget build(BuildContext context) {
    final body = widget.markdown.trim();
    final version = UpdateService().currentVersion;
    final versionText = version.isEmpty ? '…' : version;
    final markdownStyle = releaseNoticeMarkdownStyle(context);

    return Scaffold(
      backgroundColor: widget.bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(48, 26, 48, 0),
                    // 内容块整体水平居中，文字左对齐
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 图标与标题固定在页面顶部，不随正文滚动
                        Icon(widget.icon, size: 76, color: Colors.white),
                        const SizedBox(height: 20),
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            height: 1.2,
                            color: Colors.white,
                          ),
                        ),
                        if (widget.intro.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            widget.intro,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.5,
                              color: Colors.white,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        // 正文：固定在一个独立滚动框内，整页不滚动，
                        // 保证底部「好」按钮始终立刻可见。
                        Flexible(
                          child: Container(
                            width: double.infinity,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.fromLTRB(18, 4, 8, 4),
                            child: Scrollbar(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                                child: MarkdownBody(
                                  data: body.isEmpty
                                      ? kReleaseBodyFallback
                                      : body,
                                  softLineBreak: true,
                                  styleSheet: markdownStyle,
                                  onTapLink: (text, href, title) {
                                    final target = (href ?? '').trim();
                                    if (target.isNotEmpty) {
                                      UpdateService().openInBrowser(target);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        widget.action,
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 底部信息行：版本号 / 事件时间 / Github
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 48, 18),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: .75),
                  ),
                  children: [
                    TextSpan(
                      text: '版本号',
                      recognizer: widget.versionLabelRecognizer,
                    ),
                    TextSpan(text: '：$versionText    事件时间：$_eventTime    '),
                    TextSpan(
                      text: 'Github',
                      style: const TextStyle(
                        fontSize: 12,
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

/// 程序禁用页：Release tag 114.514 / 114.513 存在时由 main.dart 切换显示
///
/// 正文取自命中 Release 的 Markdown body（`UpdateService.releaseNotice`）；
/// 已删除的 tag 不再触发；「好」按钮退出软件。
class DisabledScreen extends StatefulWidget {
  /// 当前停用记录（含 Release body）；为空时回读 [UpdateService.releaseNotice]
  ///
  /// 由 main.dart 传入：body 后到时 widget 身份变化，页面会重建刷新正文，
  /// 避免先弹禁用页、正文稍后才出现的空窗。
  final ReleaseNotice? notice;

  const DisabledScreen({super.key, this.notice});

  @override
  State<DisabledScreen> createState() => _DisabledScreenState();
}

class _DisabledScreenState extends State<DisabledScreen> {
  /// 整页背景色（深红），所有文字白色系
  static const Color _bgColor = Color(0xFFAE0B2A);

  final TapGestureRecognizer _versionRecognizer = TapGestureRecognizer();

  // 隐秘后门：900ms 内连续点击 3 次"版本号"解除禁用
  int _secretTaps = 0;
  Timer? _secretTimer;

  @override
  void initState() {
    super.initState();
    _versionRecognizer.onTap = _onSecretTap;
  }

  @override
  void dispose() {
    _versionRecognizer.dispose();
    _secretTimer?.cancel();
    super.dispose();
  }

  void _onSecretTap() {
    _secretTaps++;
    _secretTimer?.cancel();
    _secretTimer = Timer(const Duration(milliseconds: 900), () {
      _secretTaps = 0;
    });
    if (_secretTaps < 3) return;
    _secretTimer?.cancel();
    _secretTaps = 0;
    // 解除禁用：同时复位 disabled 与 releaseNotice，程序不退出
    UpdateService.clearKillSwitchNotice();
  }

  Future<void> _confirmExit() async {
    try {
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final notice =
        widget.notice ??
        (UpdateService.releaseNotice.value?.kind == NoticeKind.killSwitch
            ? UpdateService.releaseNotice.value
            : null);
    final body = notice?.body ?? '';

    return ReleaseNoticeScaffold(
      bgColor: _bgColor,
      icon: Icons.warning_amber_rounded,
      title: '程序已禁用',
      markdown: body,
      versionLabelRecognizer: _versionRecognizer,
      action: FilledButton(
        onPressed: _confirmExit,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: _bgColor,
          padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: const Text(
          '好',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
