import 'package:flutter/gestures.dart';
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
    this.dismissible = true,
    this.linkText,
    this.onLinkTap,
    this.emphasisText,
    this.emphasisColor,
    this.onVisibilityChanged,
  }) : warning = true;

  const NoteBanner.info({
    super.key,
    required this.persistKey,
    required this.text,
    this.title = '提示',
    this.dismissible = true,
    this.linkText,
    this.onLinkTap,
    this.emphasisText,
    this.emphasisColor,
    this.onVisibilityChanged,
  }) : warning = false;

  /// 永久/单次隐藏的记录 key（各横条必须唯一）
  final String persistKey;

  /// 标题（红条默认「注意」，蓝条默认「提示」）
  final String title;

  /// 正文
  final String text;

  /// true = 红色警示条；false = 蓝色提示条
  final bool warning;

  /// 是否允许关闭。合规类提示（例如「进度仅供参考」）必须常驻，
  /// 传 false 时既不显示「不再显示」，也不显示「叉」，且忽略历史隐藏记录。
  final bool dismissible;

  /// 正文里要做成链接的那一段文字（必须原样出现在 [text] 里）。
  final String? linkText;

  /// 点击 [linkText] 的回调。
  final VoidCallback? onLinkTap;

  /// 放在正文下方单独强调的一段文字。
  final String? emphasisText;

  /// [emphasisText] 的文字颜色；未指定时使用提示条主色。
  final Color? emphasisColor;

  /// 横条显示状态改变时通知父组件。
  ///
  /// 主要用于多个可关闭横条组成的区域，使父组件能在全部隐藏后回收它们
  /// 与相邻内容之间的间距。
  final ValueChanged<bool>? onVisibilityChanged;

  @override
  State<NoteBanner> createState() => _NoteBannerState();
}

class _NoteBannerState extends State<NoteBanner> {
  bool _hidden = false;
  TapGestureRecognizer? _linkTap;

  @override
  void initState() {
    super.initState();
    final linkText = widget.linkText;
    if (linkText != null && linkText.isNotEmpty && widget.onLinkTap != null) {
      _linkTap = TapGestureRecognizer()..onTap = widget.onLinkTap;
    }
    if (!widget.dismissible) return;
    // 单次隐藏（会话内存）
    if (UiPrefsService.sessionDismissed.contains(widget.persistKey)) {
      _hidden = true;
      _notifyVisibilityAfterBuild();
      return;
    }
    // 永久隐藏（ui_prefs.json，异步载入）
    if (UiPrefsService.loaded) {
      _hidden = UiPrefsService.isPermanentlyDismissed(widget.persistKey);
      _notifyVisibilityAfterBuild();
    } else {
      UiPrefsService.ensureLoaded().then((_) {
        if (!mounted) return;
        setState(() {
          _hidden = UiPrefsService.isPermanentlyDismissed(widget.persistKey);
        });
        _notifyVisibilityAfterBuild();
      });
    }
  }

  void _notifyVisibilityAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onVisibilityChanged?.call(!_hidden);
    });
  }

  @override
  void dispose() {
    _linkTap?.dispose();
    super.dispose();
  }

  void _dismissForSession() {
    UiPrefsService.dismissForSession(widget.persistKey);
    if (!mounted) return;
    setState(() => _hidden = true);
    widget.onVisibilityChanged?.call(false);
  }

  Future<void> _dismissPermanently() async {
    await UiPrefsService.dismissPermanently(widget.persistKey);
    if (!mounted) return;
    setState(() => _hidden = true);
    widget.onVisibilityChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dismissible && _hidden) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final mainColor = widget.warning ? AppTheme.error : cs.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      decoration: BoxDecoration(
        color: mainColor.withValues(alpha: .08),
        borderRadius: AppShape.inner,
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.warning
                        ? Icons.warning_amber_rounded
                        : Icons.info_outline_rounded,
                    size: 20,
                    color: mainColor,
                  ),
                  const SizedBox(width: 8),
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
                ],
              ),
              const SizedBox(height: 6),
              _body(cs, mainColor),
              if (widget.emphasisText case final emphasisText?) ...[
                const SizedBox(height: 8),
                Text(
                  emphasisText,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    fontWeight: FontWeight.w700,
                    color: widget.emphasisColor ?? mainColor,
                  ),
                ),
              ],
            ],
          ),
          if (widget.dismissible)
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
                    child: const Text('不再显示', style: TextStyle(fontSize: 11.5)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
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

  /// 正文：默认纯文本；给了 [NoteBanner.linkText] 就把那一段做成链接。
  Widget _body(ColorScheme cs, Color mainColor) {
    final style = TextStyle(
      fontSize: widget.warning ? 13 : 12.5,
      height: widget.warning ? 1.5 : 1.55,
      color: widget.warning
          ? AppTheme.error.withValues(alpha: .92)
          : cs.onSurface.withValues(alpha: .8),
    );
    final linkText = widget.linkText;
    final recognizer = _linkTap;
    if (linkText == null || linkText.isEmpty || recognizer == null) {
      return Text(widget.text, style: style);
    }
    final at = widget.text.indexOf(linkText);
    if (at < 0) return Text(widget.text, style: style);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (at > 0) TextSpan(text: widget.text.substring(0, at)),
          TextSpan(
            text: linkText,
            recognizer: recognizer,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: mainColor,
              decoration: TextDecoration.underline,
              decorationColor: mainColor,
            ),
          ),
          TextSpan(text: widget.text.substring(at + linkText.length)),
        ],
      ),
    );
  }
}
