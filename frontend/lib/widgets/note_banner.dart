import 'package:flutter/material.dart';

import '../core/service/ui_prefs_service.dart';
import '../core/theme/app_theme.dart';

/// 红色警示 / 蓝色提示横条（两页统一规范）：
/// 图标、标题、正文**各自换行**，标题加粗。
/// - 红条：三角感叹号（warning_amber_rounded）
/// - 蓝条：info_outline_rounded
/// - 右上角动作：**「不再显示」**（永久，写 ui_prefs.json）与
///   **「叉」**（单次不显示，仅本次运行会话，重开 App 恢复）
class NoteBanner extends StatefulWidget {
  const NoteBanner.warning({
    super.key,
    required this.persistKey,
    required this.text,
    this.title = '注意',
  }) : warning = true;

  const NoteBanner.info({
    super.key,
    required this.persistKey,
    required this.text,
    this.title = '提示',
  }) : warning = false;

  /// 永久/单次隐藏的记录 key（各横条必须唯一）
  final String persistKey;

  /// 标题（红条默认「注意」，蓝条默认「提示」）
  final String title;

  /// 正文
  final String text;

  /// true = 红色警示条；false = 蓝色提示条
  final bool warning;

  @override
  State<NoteBanner> createState() => _NoteBannerState();
}

class _NoteBannerState extends State<NoteBanner> {
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    // 单次隐藏（会话内存）
    if (UiPrefsService.sessionDismissed.contains(widget.persistKey)) {
      _hidden = true;
      return;
    }
    // 永久隐藏（ui_prefs.json，异步载入）
    if (UiPrefsService.loaded) {
      _hidden = UiPrefsService.isPermanentlyDismissed(widget.persistKey);
    } else {
      UiPrefsService.ensureLoaded().then((_) {
        if (!mounted) return;
        setState(() {
          _hidden = UiPrefsService.isPermanentlyDismissed(widget.persistKey);
        });
      });
    }
  }

  void _dismissForSession() {
    UiPrefsService.dismissForSession(widget.persistKey);
    if (!mounted) return;
    setState(() => _hidden = true);
  }

  Future<void> _dismissPermanently() async {
    await UiPrefsService.dismissPermanently(widget.persistKey);
    if (!mounted) return;
    setState(() => _hidden = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final mainColor = widget.warning ? AppTheme.error : cs.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      decoration: BoxDecoration(
        color: mainColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: mainColor.withValues(alpha: widget.warning ? .35 : .3),
        ),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                widget.warning
                    ? Icons.warning_amber_rounded
                    : Icons.info_outline_rounded,
                size: 20,
                color: mainColor,
              ),
              const SizedBox(height: 7),
              Text(
                widget.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: widget.warning
                      ? AppTheme.error.withValues(alpha: .95)
                      : cs.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.text,
                style: TextStyle(
                  fontSize: widget.warning ? 13 : 12.5,
                  height: widget.warning ? 1.5 : 1.55,
                  color: widget.warning
                      ? AppTheme.error.withValues(alpha: .92)
                      : cs.onSurface.withValues(alpha: .8),
                ),
              ),
            ],
          ),
          Positioned(
            right: 8,
            top: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _dismissPermanently,
                  style: TextButton.styleFrom(
                    foregroundColor: mainColor.withValues(alpha: .75),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    '不再显示',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: mainColor.withValues(alpha: .65),
                  ),
                  tooltip: '本次不再显示',
                  onPressed: _dismissForSession,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
