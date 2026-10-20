import '../../providers/grades_provider.dart';

/// 核心绩口径（用户给定，勿改勿扩）：
/// - 分类依据：课程的 `kclbname` 与白名单**全字匹配**（依次两步筛选）
///   ① 先筛课程类别：kclbname ∈ 白名单（20 项）
///   ② 再筛成绩形态：**所有 PF 制（两级制）课程全部不纳入**
///     ——即剔除等级为 P/F（合格/不合格、通过/不通过）的课程，
///     如思政实践课（P）不计入
/// - 预处理仅允许两类归一：全角↔半角符号转换、去除空白字符
///   ——除此之外禁止任何模糊/子串/关键词匹配，禁止扩大课程范围
/// - 核心绩 = 剩余课程集合的**学分加权平均绩点**（Σjd ÷ Σxf），
///   复用项目现有换算规则：jd 为单科总绩点（单科绩点×学分），
///   与成绩单页"平均学分绩点 = jd / xf"同源
/// - 有效参与条件：jd 与 xf 均可解析为数值且 xf > 0（沿用 tryParse 语义）；
///   白名单内无效课程不参与计算，页筛展示也不包含（范围一致）
class CoreGpaResult {
  const CoreGpaResult({
    required this.courses,
    required this.gpa,
    required this.sumJd,
    required this.sumXf,
  });

  /// 有效参与核心绩计算的课程集合（成绩单页核心绩筛选用同一集合）
  final List<GradeCourse> courses;

  /// 核心绩（学分加权），无有效课程时为 null
  final double? gpa;
  final double sumJd;
  final double sumXf;

  /// 展示文案：null 时返回 '-'
  String get gpaText => gpa == null ? '-' : gpa!.toStringAsFixed(2);
}

class CoreGpaUtil {
  CoreGpaUtil._();

  /// kclbname 白名单（逐字原样，勿增删改）。
  /// 历次用户拍板：2026-10-20 曾整类排除'思想政治理论课'，当日改为——
  /// **恢复该类别，改为剔除所有 PF 制（两级制）课程**（先筛类别、再筛 PF）。
  /// 与官方系统核对一致（30 门 / 学分加权 3.73）。
  static const List<String> whitelist = <String>[
    '思想政治理论课',
    '思政课',
    '大学外语',
    '大学外语（拓展类课程）',
    '公共外语',
    '公共外语课',
    '公共外语（拓展类课程）',
    '公共计算机',
    '公共数学',
    '公共数学课',
    '部类共同',
    '部类共同课',
    '部类基础',
    '部类基础课',
    '专业基础课',
    '学科基础',
    '专业核心课',
    '专业必修',
    '人工智能与数据技术平台课',
    '数据与信息技术平台课',
  ];

  static final Set<String> _normalizedWhitelist = whitelist
      .map(normalize)
      .toSet();

  /// 归一化：全角 ASCII 与全角括号/斜杠等符号转半角，去除空白。
  /// 只做这两类归一，不引入其他语义变化。
  static String normalize(String s) {
    final sb = StringBuffer();
    for (final rune in s.runes) {
      int ch = rune;
      if (ch == 0x3000) continue; // 全角空格：直接去除
      // 全角 ASCII 区（！～FF01–FF5E）转半角
      if (ch >= 0xFF01 && ch <= 0xFF5E) ch -= 0xFEE0;
      final c = String.fromCharCode(ch);
      final code = c.codeUnitAt(0);
      if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D) {
        continue; // 半角空白：去除
      }
      sb.write(c);
    }
    return sb.toString();
  }

  /// 是否为核心绩白名单课程（全字匹配，预处理后严格相等）
  static bool isCore(GradeCourse course) =>
      _normalizedWhitelist.contains(normalize(course.kclbname));

  /// PF（两级制）等级集合：命中即不参与核心绩
  /// （教务优等制为 P=通过 / F=不通过，兼容中文写法与 P 大小写）
  static const Set<String> _passFailLevels = <String>{
    'P',
    'F',
    'PASS',
    'FAIL',
    '合格',
    '不合格',
    '通过',
    '不通过',
  };

  /// 课程是否为 PF 制成绩（判据：等级字段 zcjname1）
  static bool isPassFail(GradeCourse course) =>
      _passFailLevels.contains(normalize(course.zcjname1).toUpperCase());

  /// 课程是否"有效参与计算"：
  /// ① 白名单命中；② 非 PF 制；③ jd / xf 均可解析且 xf > 0
  static bool isValidForCalc(GradeCourse course) {
    return isCore(course) &&
        !isPassFail(course) &&
        double.tryParse(course.jd) != null &&
        double.tryParse(course.xf) != null &&
        double.parse(course.xf) > 0;
  }

  /// 计算核心绩：白名单 ∩ 有效课程，核心绩 = Σjd ÷ Σxf（学分加权）
  static CoreGpaResult analyze(List<GradeCourse> all) {
    final valid = <GradeCourse>[];
    double sumJd = 0;
    double sumXf = 0;
    for (final c in all) {
      if (!isCore(c) || !isValidForCalc(c)) continue;
      valid.add(c);
      sumJd += double.parse(c.jd);
      sumXf += double.parse(c.xf);
    }
    final gpa = sumXf > 0 ? sumJd / sumXf : null;
    return CoreGpaResult(
      courses: valid,
      gpa: gpa,
      sumJd: sumJd,
      sumXf: sumXf,
    );
  }
}
