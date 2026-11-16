import 'package:flutter/widgets.dart';

import '../core/service/feature_gate_service.dart';

/// 按功能组开关（Flag-1xxx）决定是否渲染 [child]。
///
/// 关闭时返回 [fallback]（默认 `SizedBox.shrink()`）——即"静默下线"：
/// 不留空位、不显示禁用提示、不写错误。开关变化时自动重绘。
///
/// 用法：
/// ```dart
/// FeatureGate(
///   flag: FeatureGateService.flag1003LatestCard,
///   child: _buildLatestCard(...),
/// )
/// ```
class FeatureGate extends StatelessWidget {
  const FeatureGate({
    super.key,
    required this.flag,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  /// 功能组编号，如 `Flag-1003`。
  final String flag;

  /// 开关开启时渲染的内容。
  final Widget child;

  /// 开关关闭时渲染的内容（默认什么都不占）。
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final service = FeatureGateService.instance;
    return ValueListenableBuilder<Map<String, bool>>(
      valueListenable: service.states,
      builder: (context, states, _) {
        final enabled = states[flag] ?? true;
        return enabled ? child : fallback;
      },
    );
  }
}

/// 命令式判断：当前是否开启某功能组。
///
/// 适合在 `build` 之外的逻辑里使用（例如按钮回调前再确认一次）。
/// 与后端一致：未知编号视为开启。
bool featureEnabled(String flag) => FeatureGateService.instance.isEnabled(flag);
