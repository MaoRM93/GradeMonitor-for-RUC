import 'dart:async';
import 'package:flutter/material.dart';

/// 全局 Toast 专用导航器 Key（main.dart 中注册到 MaterialApp）
final toastNavigatorKey = GlobalKey<NavigatorState>();

/// 全局提示浮层（Toast）单例
///
/// 规格（与 Windows 端一致）：
/// · 屏幕底部居中，距底边 56 逻辑像素，左右各留 24 边距
/// · 胶囊造型（完全圆角），背景 #ECECEC，柔和投影
/// · 文字黑色、15 号、常规粗细、无下划线、行高 1.35
/// · 宽度内容自适应，最宽 480，超出自动换行
/// · 淡入淡出各 180ms，显示 2 秒后自动消失，全程不阻挡鼠标操作
/// · 同屏只保留一个，新弹窗直接顶掉旧弹窗
class ToastHost {
  static final ToastHost instance = ToastHost._();
  factory ToastHost() => instance;
  ToastHost._();

  OverlayEntry? _entry;

  void show(String message) {
    final overlay = toastNavigatorKey.currentState?.overlay;
    if (overlay == null) return;

    // 新弹窗直接顶掉旧弹窗，同屏只保留一个
    _removeEntry();

    final entry = OverlayEntry(
      builder: (_) => _ToastCard(
        message: message,
        onFinished: _removeEntry,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  void _removeEntry() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    if (entry.mounted) entry.remove();
  }
}

/// 单条 Toast 卡片：自管淡入淡出动画与 2 秒自动关闭计时
class _ToastCard extends StatefulWidget {
  final String message;
  final VoidCallback onFinished;

  const _ToastCard({required this.message, required this.onFinished});

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    _timer = Timer(const Duration(seconds: 2), _fadeOut);
  }

  void _fadeOut() {
    if (!mounted) return;
    _ctrl.reverse().whenComplete(widget.onFinished);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 透明 Material 包裹：浮层脱离 Material 树时文字会回退调试字体
    // （黄色双下划线 + 加粗），显式指定字体家族、字重、无装饰规避
    final baseStyle = Theme.of(context).textTheme.bodyMedium;

    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(left: 24, right: 24, bottom: 56),
          child: FadeTransition(
            opacity: _ctrl,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFECECEC),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .16),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  softWrap: true,
                  style: baseStyle?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    height: 1.35,
                    color: Colors.black,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
