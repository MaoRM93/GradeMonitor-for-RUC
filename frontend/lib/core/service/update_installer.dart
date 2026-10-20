import 'dart:convert' show utf8;
import 'dart:io';

import 'package:archive/archive.dart';

import '../logger/app_logger.dart';
import 'backend_service.dart';

/// 「下载完成 → 退出即装」的安装编排
///
/// 总体流程（用户在更新弹窗点「立即安装并重启」后）：
/// 1. 解包已下载的 zip，校验内容完整；
/// 2. 在 **安装目录同级** 暂存（保证同卷 rename 原子替换），生成看守脚本；
/// 3. 先正确停掉后端（释放 18923 端口与文件占用），再启动 detached 脚本
///    （双 fork，不随 App 退出而终止），随即将主进程 exit(0)；
/// 4. 脚本等旧实例退出 → 备份旧包 → 换上新包 → 删除备份 → 自动重启新版本。
///
/// 权限与安全设计：
/// - 应用未开沙盒（Release.entitlements 无 App Sandbox），可直写安装目录；
/// - macOS 经系统 `ditto -x -k` 解包，保留可执行权限位且不写 quarantine
///   隔离标记，替换后启动不触发 Gatekeeper；
/// - Windows 为用户级安装（setup.iss `PrivilegesRequired=lowest`，
///   `%LOCALAPPDATA%\Programs\GradeMonitor`），无 UAC；dart 解包不写
///   Zone.Identifier ADS，静默安装比浏览器下载少一层拦截；
/// - 若安装目录不可写（如 app 被装进 `/Applications` 且当前为普通用户），
///   返回 `plan == null`，弹窗切换为「打开下载文件夹手动安装」。
class InstallPlan {
  const InstallPlan({
    required this.isMac,
    required this.scriptPath,
    required this.scriptArgs,
    required this.targetLabel,
  });

  final bool isMac;

  /// macOS：交给 `/bin/bash` 的看守脚本；Windows：交给 `cmd /c` 的中继批处理
  final String scriptPath;

  /// 脚本参数（macOS：[目标包, 新包, 旧PID, 暂存目录]；Windows 为空）
  final List<String> scriptArgs;

  /// 展示给用户的安装目标
  final String targetLabel;
}

/// 自动安装准备结果；[plan] 为 null 表示降级手动安装，
/// 此时 [manualDir] 为下载文件所在目录（供文件管理器定位）。
class PrepareOutcome {
  const PrepareOutcome({this.plan, this.manualDir, this.reason = ''});
  final InstallPlan? plan;
  final String? manualDir;
  final String reason;
}

class UpdateInstaller {
  static final UpdateInstaller _instance = UpdateInstaller._();
  factory UpdateInstaller() => _instance;
  UpdateInstaller._() : _log = AppLogger('update_installer');

  final AppLogger _log;

  static const String _stagePrefix = '.GradeMonitor-update-';
  static final RegExp _absWin = RegExp(r'^[A-Za-z]:');

  /// 从下载好的 zip 准备自动安装。解包为同步操作（几十 MB 约 1–3 秒），
  /// 调用方以「准备中…」状态 await 即可。
  Future<PrepareOutcome> prepareInstall(String zipPath) async {
    try {
      if (Platform.isMacOS) return _prepareMac(zipPath);
      if (Platform.isWindows) return _prepareWindows(zipPath);
      return PrepareOutcome(reason: '当前平台不支持自动安装');
    } catch (e) {
      _log.error('自动安装准备失败: $e');
      return PrepareOutcome(reason: e.toString());
    }
  }

  /// 停后端 → 启动 detached 看守脚本 → 本进程退出
  Future<void> quitAndInstall(InstallPlan plan) async {
    try {
      await BackendService().stop();
    } catch (_) {
      // 新实例启动时会自愈清理残留进程，这里失败不打断升级
    }
    if (plan.isMac) {
      await Process.start(
        '/bin/bash',
        [plan.scriptPath, ...plan.scriptArgs],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        'cmd',
        ['/c', plan.scriptPath],
        mode: ProcessStartMode.detached,
      );
    }
    // 给 detached 双 fork 留点时序余量
    await Future.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

  // ───────────────────────── macOS ─────────────────────────

  PrepareOutcome _prepareMac(String zipPath) {
    final bundlePath = _macAppBundlePath();
    if (bundlePath == null) {
      return PrepareOutcome(reason: '无法定位当前安装位置');
    }
    if (bundlePath.contains('AppTranslocation')) {
      return PrepareOutcome(reason: '应用处于系统转置目录，请先手动移动安装');
    }

    final parentDir = _parent(bundlePath);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stageRoot = _join(parentDir, '$_stagePrefix$stamp');
    Directory(stageRoot).createSync();
    try {
      if (!_probeWritable(parentDir)) {
        try {
          Directory(stageRoot).deleteSync(recursive: true);
        } catch (_) {}
        return PrepareOutcome(reason: '安装目录无写入权限（可手动替换安装包）');
      }

      // 1) ditto 解包（保留可执行位；本管道不产生 quarantine）
      final extractDir = _join(stageRoot, 'extract');
      final dr = Process.runSync(
        'ditto',
        ['-x', '-k', zipPath, extractDir],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (dr.exitCode != 0) {
        throw Exception('解包失败: ${dr.stderr.toString().trim()}');
      }

      // 2) 找到包内 App 并校验
      final newAppInner = _findAppBundle(extractDir);
      if (newAppInner == null) {
        throw Exception('安装包内未找到 GradeMonitor.app');
      }

      // 3) 暂存到待安装位置（同卷 rename，后续脚本零拷贝置换）
      final newAppStaged = _join(stageRoot, 'GradeMonitor.app');
      Process.runSync('mv', [newAppInner, newAppStaged]);
      if (!File(
        '$newAppStaged${Platform.pathSeparator}Contents'
        '${Platform.pathSeparator}Info.plist',
      ).existsSync()) {
        throw Exception('新包内容校验不通过（Info.plist 缺失）');
      }

      // 4) 生成看守脚本
      final scriptPath = _join(stageRoot, 'install.sh');
      File(scriptPath).writeAsStringSync(_macInstallScript);
      Process.runSync('chmod', ['755', scriptPath]);

      _log.info('自动安装就绪（macOS），目标: $bundlePath');
      return PrepareOutcome(
        plan: InstallPlan(
          isMac: true,
          scriptPath: scriptPath,
          scriptArgs: [bundlePath, newAppStaged, '$pid', stageRoot],
          targetLabel: bundlePath,
        ),
      );
    } catch (e) {
      // 失败清理现场，避免残留半成品目录
      try {
        Directory(stageRoot).deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// 从当前可执行文件向上定位 .app 包根（…/GradeMonitor.app）
  String? _macAppBundlePath() {
    var cur = Directory(File(Platform.resolvedExecutable).parent.path);
    for (int i = 0; i < 5; i++) {
      if (File(
        '${cur.path}${Platform.pathSeparator}Info.plist',
      ).existsSync()) {
        return cur.parent.path;
      }
      final parent = cur.parent;
      if (parent.path == cur.path) break;
      cur = parent;
    }
    return null;
  }

  /// 等旧实例退出 → 备份旧包 → 原子换新包 → 重启 → 清理暂存
  static const String _macInstallScript = r'''
#!/bin/bash
# GradeMonitor 自更新看守脚本（应用自动生成并 detached 运行）
TARGET="$1"; NEW="$2"; OLD_PID="$3"; STAGE="$4"
if [ -z "$TARGET" ] || [ -z "$NEW" ] || [ -z "$STAGE" ]; then exit 9; fi

# 1) 等待旧实例退出（最长 60 秒）
for i in $(seq 1 120); do
  kill -0 "$OLD_PID" 2>/dev/null || break
  sleep 0.5
done

# 2) 备份旧包
OLD_DIR="$(dirname "$TARGET")"
BAK="$OLD_DIR/.GradeMonitor-old-$$"
if [ -d "$TARGET" ]; then mv "$TARGET" "$BAK" || exit 2; fi

# 3) 换上新包（同卷 rename 原子替换；失败即回滚）
if [ ! -d "$NEW" ]; then
  [ -d "$BAK" ] && mv "$BAK" "$TARGET"
  exit 3
fi
if ! mv "$NEW" "$TARGET"; then
  [ -d "$BAK" ] && mv "$BAK" "$TARGET"
  exit 3
fi
rm -rf "$BAK"

# 4) 重启新版本
open "$TARGET"

# 5) 清理暂存目录（含本脚本）
rm -rf "$STAGE"
''';

  // ───────────────────────── Windows ─────────────────────────

  PrepareOutcome _prepareWindows(String zipPath) {
    final exe = Platform.resolvedExecutable;
    final installDir = File(exe).parent.path;
    final stamp = DateTime.now().millisecondsSinceEpoch;

    final stageRoot = '$installDir${Platform.pathSeparator}'
        '$_stagePrefix$stamp';
    Directory(stageRoot).createSync();
    try {
      final extractDir = '$stageRoot${Platform.pathSeparator}extract';
      Directory(extractDir).createSync();
      _extractZip(zipPath, extractDir);

      final installer = _findInstallerExe(extractDir);
      if (installer == null) {
        throw Exception('安装包内未找到安装程序 exe');
      }

      // 中继批处理：静默安装 → 自启动新版（setup.iss 的 [Run] 带
      // skipifsilent，静默安装后不会自行启动，由这里接力）
      final batchPath = '$stageRoot${Platform.pathSeparator}install.cmd';
      File(batchPath).writeAsStringSync(
        '@echo off\r\n'
        '"$installer" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES'
        ' /FORCECLOSEAPPLICATIONS\r\n'
        'if not errorlevel 1 start "" "${_winQuoteSafe(exe)}"\r\n'
        'del /q "%~f0"\r\n',
      );

      _log.info('自动安装就绪（Windows），安装器: $installer');
      return PrepareOutcome(
        plan: InstallPlan(
          isMac: false,
          scriptPath: batchPath,
          scriptArgs: const [],
          targetLabel: installDir,
        ),
      );
    } catch (e) {
      _log.error('Windows 自动安装准备失败: $e');
      try {
        Directory(stageRoot).deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  String _winQuoteSafe(String path) => path.replaceAll('"', '');

  /// 找 Inno 安装器：优先名称含 setup/install 的 exe，其次唯一 exe
  String? _findInstallerExe(String root) {
    final candidates = <String>[];
    final queue = <Directory>[Directory(root)];
    int depth = 0;
    while (queue.isNotEmpty && depth <= 2) {
      final next = <Directory>[];
      for (final d in queue) {
        for (final e in d.listSync(recursive: false)) {
          if (e is Directory) {
            next.add(e);
          } else if (e is File) {
            if (e.path.toLowerCase().endsWith('.exe')) {
              candidates.add(e.path);
            }
          }
        }
      }
      queue
        ..clear()
        ..addAll(next);
      depth++;
    }
    if (candidates.isEmpty) return null;
    for (final c in candidates) {
      final low = c.toLowerCase();
      if (low.contains('setup') || low.contains('install')) return c;
    }
    return candidates.length == 1 ? candidates.first : null;
  }

  void _extractZip(String zipPath, String dest) {
    final bytes = File(zipPath).readAsBytesSync();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      final out = _safeJoin(dest, file.name);
      if (file.isFile) {
        final data = file.content as List<int>;
        File(out)
          ..createSync(recursive: true)
          ..writeAsBytesSync(data);
      } else {
        Directory(out).createSync(recursive: true);
      }
    }
  }

  // ───────────────────────── 小工具 ─────────────────────────

  String _join(String base, String name) =>
      '$base${Platform.pathSeparator}$name';

  String _parent(String path) {
    final p = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final idx = p.lastIndexOf(Platform.pathSeparator);
    return idx > 0 ? p.substring(0, idx) : p;
  }

  bool _probeWritable(String dirPath) {
    final probe = File('$dirPath${Platform.pathSeparator}.gm-probe');
    try {
      probe.writeAsStringSync('ok', flush: false);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 归一/守卫 zip 内路径，防路径穿越（仅允许解到 dest 下）
  String _safeJoin(String root, String name) {
    final norm = name.replaceAll('\\', '/');
    if (norm.startsWith('/') || _absWin.hasMatch(norm)) {
      throw Exception('安装包内出现异常路径: $name');
    }
    final segs = norm.split('/');
    if (segs.contains('..')) {
      throw Exception('安装包内出现异常路径: $name');
    }
    var out = root;
    for (final s in segs) {
      if (s.isEmpty || s == '.') continue;
      out = '$out${Platform.pathSeparator}$s';
    }
    return out;
  }

  /// 在目录里找 .app（Contents/Info.plist 结构）；下探 3 层
  String? _findAppBundle(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return null;
    final queue = <Directory>[dir];
    int depth = 0;
    while (queue.isNotEmpty && depth <= 3) {
      final next = <Directory>[];
      for (final d in queue) {
        for (final e in d.listSync(recursive: false).whereType<Directory>()) {
          if (File(
            '$e${Platform.pathSeparator}Contents'
            '${Platform.pathSeparator}Info.plist',
          ).existsSync()) {
            return e.path;
          }
          next.add(e);
        }
      }
      queue
        ..clear()
        ..addAll(next);
      depth++;
    }
    return null;
  }
}
