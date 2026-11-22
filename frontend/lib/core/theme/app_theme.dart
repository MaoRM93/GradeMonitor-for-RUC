import 'package:flutter/material.dart';

import '../service/ui_prefs_service.dart';

enum ThemePreset {
  rucRed,
  glacierBlue,
  sageGreen,
  snowWhite,
  obsidianGold,
  classicBlue,
}

extension ThemePresetInfo on ThemePreset {
  String get id => switch (this) {
    ThemePreset.classicBlue => 'classic_blue',
    ThemePreset.rucRed => 'ruc_red',
    ThemePreset.glacierBlue => 'glacier_blue',
    ThemePreset.sageGreen => 'sage_green',
    ThemePreset.snowWhite => 'snow_white',
    ThemePreset.obsidianGold => 'obsidian_gold',
  };

  String get label => switch (this) {
    ThemePreset.rucRed => '人大红',
    ThemePreset.glacierBlue => '冰川蓝',
    ThemePreset.sageGreen => '鼠尾草绿',
    ThemePreset.snowWhite => '典雅灰',
    ThemePreset.obsidianGold => '古檀褐',
    ThemePreset.classicBlue => '经典蓝',
  };

  String get description => switch (this) {
    ThemePreset.rucRed => '庄重温暖的人大红',
    ThemePreset.glacierBlue => '清透冷静的冰川蓝',
    ThemePreset.sageGreen => '安静舒展的鼠尾草绿',
    ThemePreset.snowWhite => '克制、典雅的中性灰',
    ThemePreset.obsidianGold => '温润沉静的古檀褐',
    ThemePreset.classicBlue => '沿用熟悉的清爽蓝色界面',
  };
}

class _Palette {
  const _Palette(
    this.seed,
    this.primary,
    this.lightBg,
    this.lightSurface,
    this.lightOutline,
    this.darkBg,
    this.darkSurface,
    this.darkOutline,
    this.darkPrimary,
  );
  final Color seed;
  final Color primary;
  final Color lightBg;
  final Color lightSurface;
  final Color lightOutline;
  final Color darkBg;
  final Color darkSurface;
  final Color darkOutline;
  final Color darkPrimary;
}

/// GradeMonitor 的 Material 3 Expressive 主题工厂。
class AppTheme {
  AppTheme._();

  static const ThemePreset defaultPreset = ThemePreset.rucRed;
  static const Color seedColor = Color(0xFF1E88E5);
  static const Color primaryDeep = Color(0xFF1565C0);
  static const Color primarySky = Color(0xFF0288D1);
  static const Color accentBright = Color(0xFF60A5FA);
  static const Color lightBg = Color(0xFFF8FAFC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE2E8F0);
  static const Color darkBg = Color(0xFF0F172A);
  static const Color darkSurface = Color(0xFF1E293B);
  static const Color darkBorder = Color(0xFF334155);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);

  /// Windows 端显式使用系统自带的微软雅黑；macOS 会按 fallback 回退到苹方。
  /// 这里必须保留为常量，页面中已有 const TextStyle 直接引用此字体名。
  static const String sansFontFamily = 'Microsoft YaHei';
  static const String serifFontFamily = 'SourceHanSerifSC';
  static const String fontFamily = sansFontFamily;
  static const double fontScale = 1.12;

  static const Map<ThemePreset, _Palette> _palettes = {
    ThemePreset.classicBlue: _Palette(
      seedColor,
      primaryDeep,
      lightBg,
      lightSurface,
      lightBorder,
      darkBg,
      darkSurface,
      darkBorder,
      accentBright,
    ),
    ThemePreset.rucRed: _Palette(
      Color(0xFFAE0B2A),
      Color(0xFFAE0B2A),
      Color(0xFFFFF8F7),
      Colors.white,
      Color(0xFFF0D9DE),
      Color(0xFF1B1114),
      Color(0xFF2B1A1F),
      Color(0xFF52353D),
      Color(0xFFFFB2BE),
    ),
    ThemePreset.glacierBlue: _Palette(
      Color(0xFF34618A),
      Color(0xFF34618A),
      Color(0xFFF6F9FC),
      Colors.white,
      Color(0xFFD7E3EF),
      Color(0xFF101820),
      Color(0xFF1B2A36),
      Color(0xFF3A5265),
      Color(0xFFA9CDEA),
    ),
    ThemePreset.sageGreen: _Palette(
      Color(0xFF486548),
      Color(0xFF486548),
      Color(0xFFF7FAF5),
      Colors.white,
      Color(0xFFD8E3D4),
      Color(0xFF121A14),
      Color(0xFF202C22),
      Color(0xFF405341),
      Color(0xFFB3CFA9),
    ),
    ThemePreset.snowWhite: _Palette(
      Color(0xFF505B64),
      Color(0xFF505B64),
      Color(0xFFFAFAF7),
      Colors.white,
      Color(0xFFDEE2E4),
      Color(0xFF16191C),
      Color(0xFF252A2E),
      Color(0xFF454D53),
      Color(0xFFD5DFE7),
    ),
    ThemePreset.obsidianGold: _Palette(
      Color(0xFF78602F),
      Color(0xFF78602F),
      Color(0xFFFAF7F0),
      Color(0xFFFFFDF8),
      Color(0xFFE6DDCA),
      Color(0xFF171510),
      Color(0xFF27231C),
      Color(0xFF514938),
      Color(0xFFE2C58C),
    ),
  };

  static ThemePreset presetForId(String? value) => ThemePreset.values
      .firstWhere((preset) => preset.id == value, orElse: () => defaultPreset);
  static Color previewColor(ThemePreset preset) => _palettes[preset]!.primary;
  static ThemeData get lightTheme => lightThemeFor(defaultPreset);
  static ThemeData get darkTheme => darkThemeFor(defaultPreset);
  static ThemeData lightThemeFor(ThemePreset preset) =>
      themeFor(preset, Brightness.light);
  static ThemeData darkThemeFor(ThemePreset preset) =>
      themeFor(preset, Brightness.dark);

  static ThemeData themeFor(ThemePreset preset, Brightness brightness) {
    final p = _palettes[preset]!;
    final dark = brightness == Brightness.dark;
    final bg = dark ? p.darkBg : p.lightBg;
    final surface = dark ? p.darkSurface : p.lightSurface;
    final outline = dark ? p.darkOutline : p.lightOutline;
    final primary = dark ? p.darkPrimary : p.primary;
    // `surface` is the page's neutral base.  Expressive groups must sit on a
    // visibly different container tone; using the scaffold background here
    // makes every group disappear in both brightness modes.
    final surfaceContainerHighest = Color.alphaBlend(
      (dark ? Colors.white : primary).withValues(alpha: dark ? .12 : .085),
      surface,
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: p.seed,
      brightness: brightness,
      primary: primary,
      onPrimary: dark ? Colors.black : Colors.white,
      surface: surface,
      surfaceContainerHighest: surfaceContainerHighest,
      outline: outline,
      error: error,
    );
    final type = Typography.material2021();
    final basicText = (dark ? type.white : type.black)
        .merge(type.englishLike)
        .apply(
          fontFamily: sansFontFamily,
          fontFamilyFallback: const [
            'PingFang SC',
            'Microsoft YaHei',
            'Noto Sans CJK SC',
          ],
        );
    final text = basicText.copyWith(
      displayLarge: basicText.displayLarge?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      displayMedium: basicText.displayMedium?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      displaySmall: basicText.displaySmall?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      headlineLarge: basicText.headlineLarge?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      headlineMedium: basicText.headlineMedium?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      headlineSmall: basicText.headlineSmall?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      titleLarge: basicText.titleLarge?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
      titleMedium: basicText.titleMedium?.copyWith(
        fontFamily: serifFontFamily,
        fontWeight: FontWeight.w900,
        fontFamilyFallback: const [
          'Songti SC',
          'STSong',
          'SimSun',
          'Noto Serif CJK SC',
        ],
      ),
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      fontFamily: sansFontFamily,
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: serifFontFamily,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceContainerHighest,
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppShape.outer),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: RoundedRectangleBorder(borderRadius: AppShape.inner),
        selectedIconTheme: IconThemeData(
          color: scheme.onPrimaryContainer,
          size: 22,
        ),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
        labelType: NavigationRailLabelType.all,
        groupAlignment: -.35,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppShape.outer),
      ),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        floatingLabelStyle: TextStyle(color: scheme.primary),
        border: OutlineInputBorder(
          borderRadius: AppShape.inner,
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppShape.inner,
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppShape.inner,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppShape.inner,
          borderSide: const BorderSide(color: error),
        ),
      ),
      dividerTheme: DividerThemeData(color: outline, thickness: .7, space: 1),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primary.withValues(alpha: .16),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: .12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary.withValues(alpha: .35)
              : scheme.surfaceContainerHighest,
        ),
      ),
      // 按钮不是"容器"，不参与外轮廓的大小圆角层级：按 M3 默认形态走胶囊，
      // 该大就大。把它压成 8px 的圆角矩形会让所有操作按钮退化成表格单元格。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: const StadiumBorder()),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: const StadiumBorder(),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppShape.outer),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Color.alphaBlend(
          scheme.onSurface.withValues(alpha: dark ? .10 : .06),
          surfaceContainerHighest,
        ),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppShape.outer),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: AppShape.inner,
        ),
        textStyle: TextStyle(fontSize: 12, color: scheme.onInverseSurface),
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        displayColor: scheme.onSurface,
        bodyColor: scheme.onSurface,
      ),
    );
  }
}

/// 全程序统一的形状语言。
///
/// 一条规则贯穿所有界面：**只有容器最外侧的四角使用大圆角，其余全部小圆角**。
/// 层级关系一律靠表面色差表达，不使用阴影 —— 阴影会在深色模式与
/// 多种主题色下产生脏边，而色差在任何主题下都成立。
class AppShape {
  AppShape._();

  /// 主页仪表板组合卡片专用的大圆角。
  ///
  /// 只有仪表板底部那组统计卡用这个值，其余所有容器一律用 [cornerLarge]。
  static const double cornerHero = 32;

  /// 除仪表板外，所有容器最外侧四角的大圆角。
  static const double cornerLarge = 20;

  /// 容器内部所有元素的小圆角。
  static const double cornerSmall = 8;

  /// 同组元素之间露出的底色缝隙。
  static const double gapInner = 2;

  /// 相邻内容组之间的间距。
  static const double gapGroup = 14;

  /// 相邻版块之间的间距。
  static const double gapSection = 24;

  static const Radius heroRadius = Radius.circular(cornerHero);
  static const Radius largeRadius = Radius.circular(cornerLarge);
  static const Radius smallRadius = Radius.circular(cornerSmall);

  /// 仪表板组合卡片：四角全用 [cornerHero]。
  static const BorderRadius hero = BorderRadius.all(heroRadius);

  /// 独立容器：四角全大。
  static const BorderRadius outer = BorderRadius.all(largeRadius);

  /// 容器内部元素：四角全小。
  static const BorderRadius inner = BorderRadius.all(smallRadius);

  /// 竖向分段列表中的一项：整组首尾用大圆角，中间项全小。
  static BorderRadius segmented({required bool first, required bool last}) {
    return BorderRadius.only(
      topLeft: first ? largeRadius : smallRadius,
      topRight: first ? largeRadius : smallRadius,
      bottomLeft: last ? largeRadius : smallRadius,
      bottomRight: last ? largeRadius : smallRadius,
    );
  }

  /// 单行多列组合中的一格：只有整组最左一格的左侧两角、最右一格的右侧
  /// 两角用大圆角，其余（含中间的上下角）一律小圆角。
  ///
  /// 与 [gridCell] 的区别：那个按行列二维推导，这个只按一维左右推导。
  static BorderRadius gridRow({required bool first, required bool last}) {
    return BorderRadius.only(
      topLeft: first ? largeRadius : smallRadius,
      bottomLeft: first ? largeRadius : smallRadius,
      topRight: last ? largeRadius : smallRadius,
      bottomRight: last ? largeRadius : smallRadius,
    );
  }

  /// 网格中的一格：只有整组最外侧的四角用大圆角。
  ///
  /// 目前只有主页仪表板的统计卡用它，因此取 [cornerHero]；
  /// 其余容器走 [outer] / [segmented]，统一 [cornerLarge]。
  static BorderRadius gridCell({
    required bool topRow,
    required bool bottomRow,
    required bool first,
    required bool last,
  }) {
    return BorderRadius.only(
      topLeft: topRow && first ? heroRadius : smallRadius,
      topRight: topRow && last ? heroRadius : smallRadius,
      bottomLeft: bottomRow && first ? heroRadius : smallRadius,
      bottomRight: bottomRow && last ? heroRadius : smallRadius,
    );
  }

  /// 内容组底色：比页面底色高一阶。
  static Color groupFill(ColorScheme scheme) => scheme.surfaceContainerHighest;

  /// 组内嵌块底色：在组底色上再叠一阶，用来替代内部分割线。
  static Color insetFill(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return Color.alphaBlend(
      scheme.onSurface.withValues(alpha: dark ? .06 : .04),
      scheme.surfaceContainerHighest,
    );
  }

  /// 浮层底色：需要脱离页面的浮起元素靠这一档色差区分，不靠阴影。
  static Color overlayFill(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return Color.alphaBlend(
      scheme.onSurface.withValues(alpha: dark ? .10 : .06),
      scheme.surfaceContainerHighest,
    );
  }
}

/// 监听该控制器即可让 MaterialApp 在运行时应用并保存主题选择。
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();
  ThemePreset _preset = AppTheme.defaultPreset;
  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;
  ThemePreset get preset => _preset;
  ThemeMode get mode => _mode;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    await UiPrefsService.ensureLoaded();
    _preset = AppTheme.presetForId(
      UiPrefsService.readPref(UiPrefsService.prefThemePreset),
    );
    _mode = switch (UiPrefsService.readPref(UiPrefsService.prefThemeMode)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _loaded = true;
    notifyListeners();
  }

  Future<void> setPreset(ThemePreset value) async {
    if (_preset == value) return;
    _preset = value;
    notifyListeners();
    await UiPrefsService.writePref(UiPrefsService.prefThemePreset, value.id);
  }

  Future<void> setMode(ThemeMode value) async {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
    final id = switch (value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await UiPrefsService.writePref(UiPrefsService.prefThemeMode, id);
  }
}
