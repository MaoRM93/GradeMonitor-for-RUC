import 'package:flutter/material.dart';

import '../../core/service/update_service.dart';

/// 右上角通知广播卡片：114 号段（除 513/514/515）的 Release 正文，
/// 纯文本展示，只有「好」一个按钮，点掉即关闭，不影响任何其他状态。
class BroadcastToast extends StatelessWidget {
  const BroadcastToast({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReleaseNotice?>(
      valueListenable: UpdateService.broadcastNotice,
      builder: (context, notice, child) {
        final visible =
            notice != null &&
            notice.kind == NoticeKind.broadcast &&
            !UpdateService.disabled.value;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -.06),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: visible
              ? _BroadcastCard(key: ValueKey(notice.tag), notice: notice)
              : const SizedBox.shrink(),
        );
      },
    );
  }
}

class _BroadcastCard extends StatelessWidget {
  final ReleaseNotice notice;

  const _BroadcastCard({super.key, required this.notice});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 320,
        constraints: const BoxConstraints(maxHeight: 420),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1B2534) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .38 : .14),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_active_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '提示',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                _CloseIconButton(onTap: UpdateService.dismissBroadcast),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 4),
                child: SelectableText(
                  notice.body.isEmpty ? '本次通知没有正文内容。' : notice.body,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: colorScheme.onSurface.withValues(alpha: .85),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: UpdateService.dismissBroadcast,
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(64, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('好'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseIconButton extends StatelessWidget {
  final VoidCallback onTap;

  const _CloseIconButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          Icons.close_rounded,
          size: 16,
          color: colorScheme.onSurface.withValues(alpha: .4),
        ),
      ),
    );
  }
}
