/// 前端统一日志模块
///
/// - Windows: %APPDATA%\GradeMonitor\logs\frontend.log
/// - macOS:   ~/Library/Application Support/GradeMonitor/logs/frontend.log
///           （开发模式下若存在项目 logs/ 目录则优先使用）
/// - 同时输出到 debugPrint (Flutter 控制台)
/// - 支持日志级别过滤
/// - 日志轮转（方案 B）：
///   * 单文件超过 [_maxBytes] 自动轮转：frontend.log → frontend.log.1（仅保留一代）
///   * 每 [_reconcileInterval] 对账一次：文件被外部截断/删除时自动自愈
///
/// 背景：Dart 的 FileMode.append 句柄只跟踪内部写位置，不感知外部截断
/// （外部 `truncate -s 0` / `rm` 后，写入会落在旧偏移，把文件逻辑大小撑回去），
/// 因此本模块自行对账，并在文件被外部动过时重建/复位句柄。
///
/// 实现：单写入句柄 RandomAccessFile + 内部串行 IO 队列。
/// RAF 不允许并发未决操作，因此所有 IO（写/截断/关/开/改名）与
/// 所有"依赖实际文件状态"的决策都必须排队按序执行。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// 日志级别
enum LogLevel { debug, info, warning, error }

/// 获取日志目录（绝对路径）
String _getLogDir() {
  // 回退：尝试从可执行文件路径推导（开发模式或便携部署时，
  // 向上查找含 logs/ 目录的项目根，兼容 macOS .app 与 Windows 目录布局）
  try {
    final exeDir = Directory(Platform.resolvedExecutable).parent;
    var dir = exeDir;
    for (int i = 0; i < 6; i++) {
      final logsDir = Directory('${dir.path}/logs');
      if (logsDir.existsSync()) {
        return logsDir.path;
      }
      dir = dir.parent;
    }
  } catch (_) {}

  // 平台标准应用数据目录
  if (Platform.isMacOS) {
    return _homePath('Library/Application Support/GradeMonitor/logs');
  }
  // Windows: %APPDATA%\GradeMonitor\logs
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    return '$appData\\GradeMonitor\\logs';
  }
  // 其他平台兜底
  return _homePath('.grademonitor/logs');
}

/// 拼接用户主目录下的相对路径
String _homePath(String relative) {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return '$home/$relative';
}

/// 前端日志记录器
///
/// 所有实例共享单例的写入通道；轮转后各实例通过 [_instance]
/// 动态跟踪当前句柄，无需感知句柄被替换。
class AppLogger {
  static AppLogger? _instance;

  /// 单个日志文件的最大字节数（超过即轮转）
  static const int _maxBytes = 8 * 1024 * 1024; // 8 MB

  /// 对账周期
  static const Duration _reconcileInterval = Duration(seconds: 30);

  /// 文件头探测字节数（用于识别外部截断留下的"零洞"）
  static const int _headProbeBytes = 48;

  /// 轮转期间的缓冲上限，防止极端情况下内存堆积
  static const int _pendingLimit = 4096;

  final String _name;
  final LogLevel _minLevel;

  // —— 以下共享状态只有单例会真正使用 ——
  File? _file;

  /// 单一写入句柄。所有 IO 通过 [_ioQueue] 串行访问。
  RandomAccessFile? _raf;

  /// 串行 IO 队列的尾部。任何异常都在节点内消化，队列永不断链。
  Future<void> _ioQueue = Future<void>.value();

  /// 当前内部写位置（UTF-8 字节）。轮转/自愈时随句柄复位。
  int _position = 0;

  /// 决策窗口标志：从"轮转已计划"到"待写回放完成"期间，新日志进 [_pending]
  bool _rotating = false;
  final List<String> _pending = <String>[];

  Timer? _reconcileTimer;

  AppLogger._(this._name, this._minLevel);

  /// 初始化日志系统（应在 main() 中调用）
  static Future<void> init({LogLevel minLevel = LogLevel.info}) async {
    if (_instance != null) return;

    final logger = AppLogger._('grademonitor', minLevel);
    _instance = logger;
    try {
      final logDirPath = _getLogDir();
      final logDir = Directory(logDirPath);
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final logFile = File('$logDirPath/frontend.log');
      await logger._open(logFile);
      logger._startReconcile();
      logger.info('=== GradeMonitor Frontend 启动 ===');
      logger.info('日志文件: ${logFile.absolute.path}');
    } catch (e) {
      debugPrint('[AppLogger] Failed to initialize file logging: $e');
      if (logger._raf == null) {
        logger.info('=== GradeMonitor Frontend 启动 (仅控制台) ===');
      } else {
        logger.info('=== GradeMonitor Frontend 启动 ===');
      }
    }
  }

  /// 获取指定模块的 logger
  factory AppLogger(String name) {
    if (_instance == null) {
      // 未初始化时创建仅控制台的 logger
      debugPrint('[AppLogger] Not initialized, using console-only logger');
      _instance = AppLogger._(name, LogLevel.debug);
    }
    return AppLogger._(name, _instance!._minLevel);
  }

  /// 释放资源
  static void dispose() {
    final core = _instance;
    if (core == null) return;
    core._reconcileTimer?.cancel();
    core._reconcileTimer = null;
    final raf = core._raf;
    core._raf = null;
    if (raf != null) {
      // close 也要排队（RAF 不允许并发未决操作），应用退出时无需等待结果
      core._enqueue(() async {
        try {
          await raf.close();
        } catch (_) {}
      });
    }
    _instance = null;
  }

  // ---------- 日志方法 ----------

  void debug(String message) {
    _log(LogLevel.debug, message);
  }

  void info(String message) {
    _log(LogLevel.info, message);
  }

  void warning(String message) {
    _log(LogLevel.warning, message);
  }

  void error(String message, [Object? error, StackTrace? stackTrace]) {
    final buffer = StringBuffer(message);
    if (error != null) {
      buffer.write(' | Error: $error');
    }
    if (stackTrace != null) {
      buffer.write('\n$stackTrace');
    }
    _log(LogLevel.error, buffer.toString());
  }

  void _log(LogLevel level, String message) {
    if (level.index < _minLevel.index) return;

    final timestamp = _now();
    final levelStr = level.name.toUpperCase().padRight(7);
    final line = '$timestamp | $levelStr | $_name | $message';

    // 控制台输出
    if (level == LogLevel.error) {
      debugPrint('\x1B[31m$line\x1B[0m'); // 红色
    } else if (level == LogLevel.warning) {
      debugPrint('\x1B[33m$line\x1B[0m'); // 黄色
    } else {
      debugPrint(line);
    }

    // 文件输出：始终经由单例写入，轮转后自动指向新句柄
    final core = _instance ?? this;
    core._handleFileWrite(line);
  }

  // ---------- 文件写入 ----------

  /// 决策窗口内：新日志先暂存；窗口外：直接挂入 IO 队列
  void _handleFileWrite(String line) {
    if (_rotating) {
      _pending.add(line);
      if (_pending.length > _pendingLimit) {
        _pending.removeAt(0);
      }
      return;
    }
    _issueWrite(line);
  }

  /// 把一行日志挂入串行队列；位置累计发生在写节点执行时（与文件真实状态一致），
  /// 超过阈值即安排轮转。
  void _issueWrite(String line) {
    final data = utf8.encode('$line\n');
    _enqueue(() async {
      final raf = _raf;
      if (raf == null) return;
      await raf.writeFrom(data);
      _position += data.length;
      if (_position >= _maxBytes) {
        _rotate(); // 不 await：节点等待自身所在的队列会死锁
      }
    });
  }

  /// 追加一个 IO 步骤到串行队列。异常在节点内消化，队列永不断链。
  void _enqueue(Future<void> Function() job) {
    final next = _ioQueue.then((_) async {
      try {
        await job();
      } catch (e) {
        debugPrint('[AppLogger] IO 错误: $e');
      }
    });
    _ioQueue = next;
  }

  // ---------- 打开 / 对账 / 轮转 ----------

  /// 启动时打开日志文件
  ///
  /// - 文件超过阈值 → 先归档为 .1 再从 0 开始
  /// - 文件头是零洞（曾被外部截断）→ 直接清空重建，不归档脏文件
  /// - 正常存在 → 在现有文件末尾继续追加（写位置显式对齐 EOF）
  Future<void> _open(File logFile) async {
    _file = logFile;
    _position = 0;
    _raf = null;

    int existing = 0;
    bool foreign = false;
    try {
      if (await logFile.exists()) {
        existing = await logFile.length();
        if (existing > 0) {
          foreign = await _hasBlankHead(logFile);
        }
      }
    } catch (_) {
      existing = 0;
    }

    try {
      if (existing >= _maxBytes || foreign) {
        if (foreign) {
          // 曾被外部整段截断：清空从 0 开始
          await logFile.writeAsBytes(const <int>[], mode: FileMode.write);
        } else {
          // 正常超限：轮转归档
          final backup = File('${logFile.path}.1');
          if (await backup.exists()) {
            await backup.delete();
          }
          await logFile.rename(backup.path);
        }
        existing = 0;
      }
    } catch (e) {
      // 归档/清理失败不阻塞启动，退化为在原文件追加
      debugPrint('[AppLogger] open 阶段归档失败: $e');
    }

    try {
      final raf = await logFile.open(mode: FileMode.writeOnlyAppend);
      final len = await logFile.length();
      await raf.setPosition(len);
      _raf = raf;
      _position = len;
    } catch (e) {
      debugPrint('[AppLogger] 打开日志文件失败: $e');
      _raf = null;
      _position = 0;
    }
  }

  /// 读取文件头，判断是否全是零（外部截断后的洞特征）
  Future<bool> _hasBlankHead(File file) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(_headProbeBytes);
        return head.isNotEmpty && head.every((b) => b == 0);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 启动对账定时器
  void _startReconcile() {
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer.periodic(_reconcileInterval, (_) {
      _reconcile();
    });
  }

  /// 周期对账（决策在队列内执行，采样与写序一致）：
  /// - 文件被删除 → 关闭旧句柄并重建
  /// - 文件被外部截断（len==0 / 零洞）→ 句柄内就地 truncate + 复位写位置
  /// - 内部位置超限 → 正常轮转归档 .1
  Future<void> _reconcile() async {
    if (!identical(this, _instance) || _rotating) return;
    _rotating = true;
    _enqueue(() async {
      try {
        final file = _file;
        if (file == null) return;
        bool deleted = false;
        bool blank = false;
        try {
          if (!await file.exists()) {
            deleted = true;
          } else {
            final len = await file.length();
            if (len == 0 && _position > 0) {
              blank = true;
            } else if (len > 0 && await _hasBlankHead(file)) {
              blank = true;
            }
          }
        } catch (e) {
          debugPrint('[AppLogger] 对账探测失败: $e');
        }
        if (deleted) {
          debugPrint('[AppLogger] 日志文件被删除，重建句柄');
          await _reopenAt(file, archive: false);
        } else if (blank) {
          debugPrint('[AppLogger] 检测到外部截断，就地重建日志');
          final raf = _raf;
          if (raf != null) {
            try {
              await raf.truncate(0);
              await raf.setPosition(0);
              _position = 0;
            } catch (e) {
              debugPrint('[AppLogger] 就地重建失败: $e');
            }
          }
        } else if (_position >= _maxBytes) {
          await _rotateCore(file, archive: true);
        }
      } catch (e) {
        debugPrint('[AppLogger] reconcile failed: $e');
      }
    });
    await _ioQueue;
    await _drainPending();
  }

  /// 阈值触发的轮转
  ///
  /// 决策同样在队列内：若发现文件已被外部删除/清空，则不归档脏文件、
  /// 直接重建；否则关闭句柄 → 归档 .1 → 重新打开新文件。
  Future<void> _rotate() async {
    if (_rotating) return;
    _rotating = true;
    _enqueue(() async {
      try {
        final file = _file;
        if (file == null) return;
        bool deleted = false;
        bool shrunk = false;
        try {
          if (!await file.exists()) {
            deleted = true;
          } else {
            final len = await file.length();
            shrunk = _position > 0 &&
                len < _position ~/ 2 &&
                len < 1024 * 1024;
          }
        } catch (e) {
          debugPrint('[AppLogger] 轮转探测失败: $e');
        }
        if (deleted || shrunk) {
          debugPrint('[AppLogger] 轮转前发现文件被外部动过，直接重建');
          await _reopenAt(file, archive: false);
        } else {
          await _rotateCore(file, archive: true);
        }
      } catch (e) {
        debugPrint('[AppLogger] rotate failed: $e');
      }
    });
    await _ioQueue;
    await _drainPending();
  }

  /// 轮转核心：当前的决策已在 IO 队列内执行
  ///
  /// [archive] 为 true 时把当前文件改名为 .1（覆盖上一代），
  /// 否则原地重建（文件被外部删除时由 open 自动重新创建）。
  Future<void> _rotateCore(File file, {required bool archive}) async {
    final old = _raf;
    _raf = null;
    try {
      await old?.close();
    } catch (e) {
      debugPrint('[AppLogger] 关闭旧句柄失败: $e');
    }
    if (archive) {
      final backup = File('${file.path}.1');
      if (await backup.exists()) {
        await backup.delete();
      }
      try {
        await file.rename(backup.path);
      } catch (e) {
        // 改名失败退化为在原文件追加
        debugPrint('[AppLogger] 归档失败: $e');
      }
    }
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    final len = await file.length();
    await raf.setPosition(len);
    _raf = raf;
    _position = len;
  }

  /// 重新打开日志文件（文件可能不存在，open 会自动创建）
  Future<void> _reopenAt(File file, {required bool archive}) async {
    final old = _raf;
    _raf = null;
    try {
      await old?.close();
    } catch (e) {
      debugPrint('[AppLogger] 关闭旧句柄失败: $e');
    }
    if (archive) {
      // 理论上不会走这条路径（删档不归档），防御性保留
      final backup = File('${file.path}.1');
      if (await backup.exists()) {
        await backup.delete();
      }
      try {
        await file.rename(backup.path);
      } catch (e) {
        debugPrint('[AppLogger] 归档失败: $e');
      }
    }
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    final len = await file.length();
    await raf.setPosition(len);
    _raf = raf;
    _position = len;
  }

  /// 决策窗口结束：回放窗口期暂存的日志
  Future<void> _drainPending() async {
    final pending = List<String>.from(_pending);
    _pending.clear();
    _rotating = false;
    for (final line in pending) {
      _issueWrite(line);
    }
  }

  // ---------- 时间戳 ----------

  String _now() {
    final now = DateTime.now();
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '${_fmt(now.year)}-${_fmt(now.month)}-${_fmt(now.day)} '
        '${_fmt(now.hour)}:${_fmt(now.minute)}:${_fmt(now.second)}.$ms';
  }

  static String _fmt(int n) => n.toString().padLeft(2, '0');
}
