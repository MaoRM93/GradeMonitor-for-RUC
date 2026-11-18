import 'package:flutter/material.dart';

import '../../core/service/update_service.dart';
import '../../core/theme/app_theme.dart';

/// 右上角通知广播卡片：114 号段（除 513/514/515）的 Release 正文，
/// 纯文本展示，最多三张纵向堆叠；每张只关闭自身，不影响其他通知。
class BroadcastToast extends StatelessWidget {
  const BroadcastToast({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ReleaseNotice>>(
      valueListenable: UpdateService.broadcastNotices,
      builder: (context, notices, child) {
        if (UpdateService.disabled.value || notices.isEmpty) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < notices.length; index++) ...[
                _BroadcastCard(
                  key: ValueKey(notices[index].tag),
                  notice: notices[index],
                ),
                if (index != notices.length - 1) const SizedBox(height: 12),
              ],
            ],
          ),
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
        constraints: const BoxConstraints(maxHeight: 220),
        decoration: BoxDecoration(
          // 广播卡是独立浮层：四角大圆角，靠色差与页面区分，不用阴影。
          color: isDark ? const Color(0xFF1B2534) : Colors.white,
          borderRadius: AppShape.outer,
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    notice.title.isEmpty ? '提示' : notice.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                _CloseIconButton(
                  onTap: () => UpdateService.dismissBroadcast(notice),
                ),
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
                onPressed: () => UpdateService.dismissBroadcast(notice),
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
      borderRadius: AppShape.inner,
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
