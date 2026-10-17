import 'package:flutter/material.dart';

/// GradeMonitor Material 3 蓝色调主题配置
class AppTheme {
  AppTheme._();

  // ---- 全局字体 ----
  /// Windows 默认微软雅黑，macOS 退回苹方/华文黑体
  static const String fontFamily = 'Microsoft YaHei';

  /// 全局文字缩放系数（整体放大）
  static const double fontScale = 1.12;

  // ---- 品牌色 ----
  static const Color seedColor = Color(0xFF1E88E5);
  static const Color primaryDeep = Color(0xFF1565C0);
  static const Color primarySky = Color(0xFF0288D1);
  static const Color accentBright = Color(0xFF60A5FA);

  // ---- 浅色模式 ----
  static const Color lightBg = Color(0xFFF8FAFC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE2E8F0);

  // ---- 深色模式 ----
  static const Color darkBg = Color(0xFF0F172A);
  static const Color darkSurface = Color(0xFF1E293B);
  static const Color darkBorder = Color(0xFF334155);

  // ---- 语义色 ----
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);

  /// M3 的 ThemeData 会剥掉 textTheme 的颜色（M3 设计：组件自行从 colorScheme 取色），
  /// 但部分组件（TextField 输入文字、未显式指定颜色的 Text）不会兜底，
  /// 颜色为 null 时会被渲染成白色导致浅色背景下看不清。
  /// 构造后用 copyWith 重新上色兜底（copyWith 不会再次剥色）。
  static TextTheme _paint(ThemeData theme, Color color) =>
      theme.textTheme.apply(displayColor: color, bodyColor: color);

  /// 浅色主题
  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
      primary: primaryDeep,
      onPrimary: Colors.white,
      secondary: primarySky,
      surface: lightSurface,
      surfaceContainerHighest: lightBg,
      outline: lightBorder,
    );

    // material2021 的 black/white 只有颜色没有 fontSize（几何在 englishLike），
    // 必须先合并几何再 apply，否则 fontSizeFactor != 1.0 会触发断言崩溃
    final typography = Typography.material2021();

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBg,

      // 全局字体：微软雅黑 + 整体放大
      fontFamily: fontFamily,
      textTheme: typography.black
          .merge(typography.englishLike)
          .apply(fontFamily: fontFamily, fontSizeFactor: fontScale),

      // AppBar
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: lightSurface.withValues(alpha: .85),
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),

      // Card
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: lightBorder, width: .5),
        ),
        color: lightSurface,
        margin: EdgeInsets.zero,
      ),

      // NavigationRail
      navigationRailTheme: NavigationRailThemeData(
        elevation: 0,
        backgroundColor: lightSurface.withValues(alpha: .6),
        selectedIconTheme: IconThemeData(color: colorScheme.primary, size: 22),
        unselectedIconTheme: IconThemeData(
          color: colorScheme.onSurface.withValues(alpha: .45),
          size: 22,
        ),
        selectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurface.withValues(alpha: .45),
        ),
        indicatorColor: colorScheme.primary.withValues(alpha: .1),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        labelType: NavigationRailLabelType.all,
        groupAlignment: -.35,
      ),

      // Input
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: lightBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: lightBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error),
        ),
      ),

      // Slider
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: .15),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: .08),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return colorScheme.primary;
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: .4);
          }
          return Colors.grey.withValues(alpha: .2);
        }),
      ),

      // Divider
      dividerTheme: const DividerThemeData(
        color: lightBorder,
        thickness: .5,
        space: 1,
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.onSurface.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(fontSize: 12, color: Colors.white),
      ),
    );
    // M3 构造期会剥掉 textTheme 颜色，这里重新上色，避免 null 色文字被渲染成白色
    return base.copyWith(textTheme: _paint(base, colorScheme.onSurface));
  }

  /// 深色主题
  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
      primary: accentBright,
      onPrimary: Colors.black,
      secondary: accentBright,
      surface: darkSurface,
      surfaceContainerHighest: darkBg,
      outline: darkBorder,
    );

    // 同浅色主题：先合并几何再 apply，避免 fontSize 为 null 触发断言
    final typography = Typography.material2021();

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,

      // 全局字体：微软雅黑 + 整体放大
      fontFamily: fontFamily,
      textTheme: typography.white
          .merge(typography.englishLike)
          .apply(fontFamily: fontFamily, fontSizeFactor: fontScale),

      // AppBar
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: darkBg.withValues(alpha: .85),
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),

      // Card
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: darkBorder, width: .5),
        ),
        color: darkSurface,
        margin: EdgeInsets.zero,
      ),

      // NavigationRail
      navigationRailTheme: NavigationRailThemeData(
        elevation: 0,
        backgroundColor: darkSurface.withValues(alpha: .6),
        selectedIconTheme: IconThemeData(color: colorScheme.primary, size: 22),
        unselectedIconTheme: IconThemeData(
          color: colorScheme.onSurface.withValues(alpha: .35),
          size: 22,
        ),
        selectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurface.withValues(alpha: .35),
        ),
        indicatorColor: colorScheme.primary.withValues(alpha: .15),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        labelType: NavigationRailLabelType.all,
        groupAlignment: -.35,
      ),

      // Input
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error),
        ),
      ),

      // Slider
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: .15),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: .08),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return colorScheme.primary;
          return Colors.grey;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: .4);
          }
          return Colors.grey.withValues(alpha: .15);
        }),
      ),

      // Divider
      dividerTheme: const DividerThemeData(
        color: darkBorder,
        thickness: .5,
        space: 1,
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(fontSize: 12, color: Colors.black),
      ),
    );
    // 同浅色主题：重新上色兜底
    return base.copyWith(textTheme: _paint(base, colorScheme.onSurface));
  }
}
