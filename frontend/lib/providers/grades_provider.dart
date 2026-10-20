import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/network/api_client.dart';
import '../core/logger/app_logger.dart';
import 'monitor_provider.dart';

/// 成绩课程数据模型
class GradeCourse {
  final String kth;
  final String kcname;
  final String xf;
  final String jd;
  final String cjxm1;
  final String cjxm3;
  final String zcj;
  final String xnxq;
  final String kcxz;

  /// 课程类别（kclbname，用于核心绩白名单分类）
  final String kclbname;

  /// 等级名称（zcjname1，用于识 PF/两级制课程）
  final String zcjname1;

  const GradeCourse({
    required this.kth,
    required this.kcname,
    this.xf = '',
    this.jd = '',
    this.cjxm1 = '',
    this.cjxm3 = '',
    this.zcj = '',
    this.xnxq = '',
    this.kcxz = '',
    this.kclbname = '',
    this.zcjname1 = '',
  });

  /// 平均学分绩点 = jd / xf
  String get avgGpa {
    final jdVal = double.tryParse(jd);
    final xfVal = double.tryParse(xf);
    if (jdVal == null || xfVal == null || xfVal == 0) return '-';
    return (jdVal / xfVal).toStringAsFixed(1);
  }

  factory GradeCourse.fromJson(Map<String, dynamic> json) {
    return GradeCourse(
      kth: json['kth']?.toString() ?? '',
      kcname: json['kcname']?.toString() ?? '未知课程',
      xf: json['xf']?.toString() ?? '',
      jd: json['jd']?.toString() ?? '',
      cjxm1: json['cjxm1']?.toString() ?? '',
      cjxm3: json['cjxm3']?.toString() ?? '',
      zcj: json['zcj']?.toString() ?? '',
      xnxq: json['xnxq']?.toString() ?? '',
      kcxz: json['kcxz']?.toString() ?? '',
      kclbname: json['kclbname']?.toString() ?? '',
      zcjname1: json['zcjname1']?.toString() ?? '',
    );
  }
}

/// 排名数据模型
class RankData {
  final String pm;
  final String bjpm;
  final String countnum;
  final String bjgms;
  final String pjxfjd;
  final String ndzyName;
  final String xsName;
  final String xh;

  const RankData({
    this.pm = 'N/A',
    this.bjpm = 'N/A',
    this.countnum = 'N/A',
    this.bjgms = 'N/A',
    this.pjxfjd = 'N/A',
    this.ndzyName = '未知专业',
    this.xsName = '未知姓名',
    this.xh = '未知学号',
  });

  factory RankData.fromJson(Map<String, dynamic> json) {
    return RankData(
      pm: json['pm']?.toString() ?? 'N/A',
      bjpm: json['bjpm']?.toString() ?? 'N/A',
      countnum: json['countnum']?.toString() ?? 'N/A',
      bjgms: json['bjgms']?.toString() ?? 'N/A',
      pjxfjd: json['pjxfjd']?.toString() ?? 'N/A',
      ndzyName: json['ndzy_name']?.toString() ?? '未知专业',
      xsName: json['xs_name']?.toString() ?? '未知姓名',
      xh: json['xh']?.toString() ?? '未知学号',
    );
  }
}

/// 成绩列表 Provider
class GradesNotifier extends StateNotifier<AsyncValue<List<GradeCourse>>> {
  final ApiClient _api;
  final _log = AppLogger('grades');
  bool _isFetching = false;
  bool get isFetching => _isFetching;

  GradesNotifier(this._api) : super(const AsyncValue.loading());

  Future<void> fetchGrades() async {
    // 如果已有数据，不重置为 loading，直接覆写
    final hasData = state is AsyncData;
    if (!hasData) {
      state = const AsyncValue.loading();
    }
    _isFetching = true;
    try {
      final resp = await _api.getGrades();
      if (resp.statusCode != null && resp.statusCode! >= 400) {
        final detail = resp.data is Map
            ? resp.data['detail'] ?? '未知错误'
            : '未知错误';
        throw Exception(detail);
      }
      final data = resp.data['data'] as List<dynamic>? ?? [];
      final grades = data
          .map((e) => GradeCourse.fromJson(e as Map<String, dynamic>))
          .toList();
      _log.info('成绩加载成功: ${grades.length} 门课程');
      state = AsyncValue.data(grades);
    } catch (e, st) {
      _log.error('成绩加载失败', e, st);
      if (!hasData) state = AsyncValue.error(e, st);
    } finally {
      _isFetching = false;
    }
  }
}

final gradesProvider =
    StateNotifierProvider<GradesNotifier, AsyncValue<List<GradeCourse>>>((ref) {
      final api = ref.watch(apiClientProvider);
      return GradesNotifier(api);
    });

/// 排名数据 Provider
class RankNotifier extends StateNotifier<AsyncValue<RankData?>> {
  final ApiClient _api;
  final _log = AppLogger('rank');
  bool _isFetching = false;
  bool get isFetching => _isFetching;

  RankNotifier(this._api) : super(const AsyncValue.loading());

  Future<void> fetchRank() async {
    final hasData = state is AsyncData;
    if (!hasData) {
      state = const AsyncValue.loading();
    }
    _isFetching = true;
    try {
      final resp = await _api.getRank();
      if (resp.statusCode != null && resp.statusCode! >= 400) {
        final detail = resp.data is Map
            ? resp.data['detail'] ?? '未知错误'
            : '未知错误';
        throw Exception(detail);
      }
      final data = resp.data['data'] as Map<String, dynamic>?;
      if (data != null) {
        _log.info('排名加载成功: pm=${data['pm']}');
        state = AsyncValue.data(RankData.fromJson(data));
      } else {
        _log.info('排名加载: 暂无数据');
        state = const AsyncValue.data(null);
      }
    } catch (e, st) {
      _log.error('排名加载失败', e, st);
      if (!hasData) state = AsyncValue.error(e, st);
    } finally {
      _isFetching = false;
    }
  }
}

final rankProvider = StateNotifierProvider<RankNotifier, AsyncValue<RankData?>>(
  (ref) {
    final api = ref.watch(apiClientProvider);
    return RankNotifier(api);
  },
);
