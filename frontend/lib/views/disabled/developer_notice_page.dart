import 'package:flutter/material.dart';

import '../../core/service/update_service.dart';
import 'disabled_page.dart';

/// 开发者重要提醒页（蓝色）：Release tag 114.515 存在时由 main.dart 切换显示
///
/// 与禁用页共用 [ReleaseNoticeScaffold] 的位置与字号层级，只换配色、图标与标题；
/// 正文为 114.515 的 Release body（Markdown，支持滚动）。
///
/// 语义与禁用页的关键差别：「好」按钮**只关闭本页**回到 AppNavigation，
/// 不退出软件，也从不把 [UpdateService.disabled] 置真。
class DeveloperNoticeScreen extends StatefulWidget {
  /// 当前提示记录；为空时页面仍可渲染兜底文案（例如加载期间被重建）
  final ReleaseNotice? notice;

  const DeveloperNoticeScreen({super.key, this.notice});

  @override
  State<DeveloperNoticeScreen> createState() => _DeveloperNoticeScreenState();
}

class _DeveloperNoticeScreenState extends State<DeveloperNoticeScreen> {
  /// 整页背景色（深蓝，与禁用页深红同深度），所有文字白色系
  static const Color _bgColor = Color(0xFF0B4EAE);

  /// 兜底：正常应由 main.dart 传入 notice，这里再兜一层
  ReleaseNotice? get _notice =>
      widget.notice ??
      (UpdateService.releaseNotice.value?.kind == NoticeKind.developerNotice
          ? UpdateService.releaseNotice.value
          : null);

  void _dismiss() {
    // 仅清空提示状态：disabled 保持 false，界面由 notifier 变化回到 App
    UpdateService.dismissDeveloperNotice();
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;

    return ReleaseNoticeScaffold(
      bgColor: _bgColor,
      icon: Icons.notifications_active_rounded,
      title: '来自开发者的重要提醒',
      markdown: notice?.body ?? '',
      action: FilledButton(
        onPressed: _dismiss,
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
