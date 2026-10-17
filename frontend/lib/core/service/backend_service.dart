import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../logger/app_logger.dart';

/// 后端 Python 服务管理
///
/// App 启动时自动拉起 uvicorn，关闭时自动终止。
class BackendService {
  static final BackendService _instance = BackendService._();
  factory BackendService() => _instance;
  BackendService._();

  final _log = AppLogger('backend_svc');
  Process? _process;
  bool _started = false;

  /// 启动后端服务
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final python = await _findPython();
    if (python == null) {
      _log.error('未找到 Python 解释器，无法启动后端服务');
      return;
    }

    _log.info('使用 Python: $python');

    // 杀掉可能残留的旧进程（上次非正常退出遗留）
    await _killExistingProcess();

    // 项目根目录：固定绝对路径
    const workingDir = '/Applications/Projects/GradeDetector_4';

    _log.info('工作目录: $workingDir');

    try {
      _process = await Process.start(
        python,
        [
          '-m', 'uvicorn',
          'backend.api.app:app',
          '--host', '127.0.0.1',
          '--port', '18923',
          '--log-level', 'warning', // uvicorn 自己的日志用 warning 避免重复
        ],
        workingDirectory: workingDir,
        mode: ProcessStartMode.normal,
        environment: {
          ...Platform.environment,
          'GRADEMONITOR_APP_PATH': Platform.resolvedExecutable,
        },
      );

      _log.info('后端服务已启动 (PID: ${_process!.pid})');

      // 监听后端输出（仅记录非空行到日志）
      _process!.stdout
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              _log.debug('[uvicorn] $line');
            }
          });

      _process!.stderr
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              _log.warning('[uvicorn:stderr] $line');
            }
          });

      // 监听进程退出
      _process!.exitCode.then((code) {
        _log.warning('后端服务已退出 (exit code: $code)');
        _process = null;
        _started = false;
      });

      // 等待后端就绪（最多等 5 秒）
      await _waitForReady();
    } catch (e) {
      _log.error('启动后端服务失败', e);
      _started = false;
    }
  }

  /// 停止后端服务
  Future<void> stop() async {
    if (_process == null) return;
    _log.info('正在停止后端服务...');
    try {
      _process!.kill(ProcessSignal.sigterm);
      await _process!.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _log.warning('后端未响应 SIGTERM，强制终止');
          _process!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _log.info('后端服务已停止');
    } catch (e) {
      _log.error('停止后端服务异常', e);
    }
    _process = null;
    _started = false;
  }

  /// 杀掉可能残留的旧 Python 后端进程（上次非正常退出时遗留）
  Future<void> _killExistingProcess() async {
    try {
      final result = await Process.run('lsof', ['-ti', ':18923']);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        final pids = result.stdout.toString().trim().split('\n');
        for (final pid in pids) {
          final trimmedPid = pid.trim();
          if (trimmedPid.isNotEmpty) {
            _log.warning('发现残留后端进程 PID=$trimmedPid，正在清理...');
            await Process.run('kill', ['-9', trimmedPid]);
          }
        }
        // 等待端口释放
        await Future.delayed(const Duration(seconds: 1));
      }
    } catch (_) {
      // 无法清理也无妨，uvicorn 启动时会报错，我们可以从错误中恢复
    }
  }

  /// 查找可用的 Python 解释器
  Future<String?> _findPython() async {
    const projectRoot = '/Applications/Projects/GradeDetector_4';

    // 1. 优先使用项目内的 .venv
    final venvPython = '$projectRoot/.venv/bin/python';
    if (File(venvPython).existsSync()) {
      final result = await Process.run(venvPython, [
        '-c',
        'import uvicorn; print("ok")',
      ]);
      if (result.exitCode == 0) {
        return venvPython;
      }
    }

    // 2. 尝试 Homebrew python3.11
    final brewPython = '/opt/homebrew/bin/python3.11';
    if (File(brewPython).existsSync()) {
      final result = await Process.run(brewPython, [
        '-c',
        'import uvicorn; print("ok")',
      ]);
      if (result.exitCode == 0) {
        return brewPython;
      }
    }

    // 3. 尝试系统 python3
    try {
      final result = await Process.run('python3', [
        '-c',
        'import uvicorn; print("ok")',
      ]);
      if (result.exitCode == 0) {
        return 'python3';
      }
    } catch (_) {}

    return null;
  }

  /// 等待后端就绪（轮询健康检查）
  Future<void> _waitForReady() async {
    const maxRetries = 25; // 最多等 5 秒
    for (int i = 0; i < maxRetries; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 1);
        final request = await client.get('127.0.0.1', 18923, '/');
        final response = await request.close();
        if (response.statusCode == 200) {
          _log.info('后端服务就绪 (${(i + 1) * 200}ms)');
          client.close();
          return;
        }
        client.close();
      } catch (_) {
        // 尚未就绪，继续等待
      }
    }
    _log.warning('后端服务启动超时（5 秒），可能仍在初始化中');
  }
}
