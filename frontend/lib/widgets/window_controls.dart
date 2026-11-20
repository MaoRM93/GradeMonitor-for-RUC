import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/service/feature_gate_service.dart';
import '../core/theme/app_theme.dart';
import 'feature_gate.dart';

/// 窗口内部浮层控件（Windows 专用）
///
/// 背景：Windows 端窗口用 `TitleBarStyle.hidden` 去掉了系统标题栏，原先在
/// 内容区顶部额外画了一条 36px 的自绘标题栏（应用名 + 最小化/最大化/关闭）。
/// 现在把这条横栏彻底去掉，改为：
///   * [WindowDragStrip]：窗口最顶部一条透明拖拽带（拖动移窗、双击最大化）；
///   * [WindowControlsOverlay]：内容区右上角悬浮的三键胶囊。
///
/// 两者都返回 `Positioned`，**必须直接放在同一个 Stack 里**，且排在内容之后
/// （Stack 后绘制的先命中）。
///
/// macOS 继续使用系统原生红绿灯与原生拖拽：本文件的控件在非 Windows 平台
/// 渲染为空，不占用任何布局空间，也不拦截任何手势。

/// 顶部透明拖拽带高度（逻辑像素）
const double kWindowDragStripHeight = 32.0;

/// 悬浮三键胶囊的高度
const double kWindowControlsHeight = 30.0;

/// 悬浮三键胶囊距窗口顶部的距离
const double kWindowControlsTop = 6.0;

/// 悬浮三键胶囊距窗口右边缘的距离
const double kWindowControlsRight = 12.0;

/// 单个窗口按钮的宽度
const double kWindowControlButtonWidth = 36.0;

/// 右上角为三键胶囊预留的横向空间（页面右上角有内容时用它做避让）
const double kWindowControlsReservedWidth =
    kWindowControlsRight + 3 * kWindowControlButtonWidth + 8;

/// 右上角为三键胶囊预留的纵向空间（内容需要从这之下开始排布时使用）
const double kWindowControlsReservedHeight =
    kWindowControlsTop + kWindowControlsHeight;

/// 当前是否由 App 自己绘制窗口按钮
///
/// 需要同时满足：Windows 平台 + Flag-1050 未被远程下线。
/// Flag-1050 下线时由 main.dart 把标题栏交还系统原生实现。
bool get usesInWindowControls =>
    Platform.isWindows && featureEnabled(FeatureGateService.flag1050TitleBar);

Future<void> _toggleMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

/// 窗口顶部透明拖拽带
///
/// 只接管「按住拖动」与「双击最大化」，用 `HitTestBehavior.translucent` 保证
/// 落在带子上的单击仍能穿透到下面的页面内容（返回按钮、标题等）。
class WindowDragStrip extends StatelessWidget {
  const WindowDragStrip({super.key, this.height = kWindowDragStripHeight});

  final double height;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, bool>>(
      valueListenable: FeatureGateService.instance.states,
      builder: (context, states, child) {
        if (!usesInWindowControls) return const SizedBox.shrink();
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: height,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: _toggleMaximize,
          ),
        );
      },
    );
  }
}

/// 内容区右上角悬浮的最小化 / 最大化 / 关闭
class WindowControlsOverlay extends StatefulWidget {
  const WindowControlsOverlay({super.key});

  @override
  State<WindowControlsOverlay> createState() => _WindowControlsOverlayState();
}

class _WindowControlsOverlayState extends State<WindowControlsOverlay>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, bool>>(
      valueListenable: FeatureGateService.instance.states,
      builder: (context, states, child) {
        if (!usesInWindowControls) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Positioned(
          top: kWindowControlsTop,
          right: kWindowControlsRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              height: kWindowControlsHeight,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: .74),
                borderRadius: BorderRadius.circular(kWindowControlsHeight / 2),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: .28),
                  width: .8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _WindowControlButton(
                    icon: Icons.remove_rounded,
                    tooltip: '最小化',
                    onTap: () => windowManager.minimize(),
                  ),
                  _WindowControlButton(
                    icon: _isMaximized
                        ? Icons.filter_none_rounded
                        : Icons.crop_square_rounded,
                    iconSize: _isMaximized ? 13 : 14,
                    tooltip: _isMaximized ? '还原' : '最大化',
                    onTap: _toggleMaximize,
                  ),
                  _WindowControlButton(
                    icon: Icons.close_rounded,
                    tooltip: '关闭',
                    isClose: true,
                    onTap: () => windowManager.close(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 单个窗口按钮：36×30 热区，悬停变色（关闭键悬停变红、图标转白）
class _WindowControlButton extends StatefulWidget {
  const _WindowControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
    this.iconSize = 15,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;
  final double iconSize;

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final closeHovered = widget.isClose && _hovered;
    final iconColor = closeHovered
        ? Colors.white
        : cs.onSurface.withValues(alpha: _hovered ? .92 : .62);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: kWindowControlButtonWidth,
            height: double.infinity,
            color: closeHovered
                ? AppTheme.error
                : (_hovered
                      ? cs.onSurface.withValues(alpha: .08)
                      : Colors.transparent),
            child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}
