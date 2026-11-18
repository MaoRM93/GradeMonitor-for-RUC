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
  static const String sansFontFamily = 'SourceHanSansSC';
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        floatingLabelStyle: TextStyle(color: scheme.primary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
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
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
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
