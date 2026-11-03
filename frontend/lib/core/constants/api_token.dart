import 'dart:math';

/// 本地后端访问令牌
///
/// 后端（127.0.0.1:18923）原先零鉴权 + CORS `*`，本机任意网页/进程都能
/// 读取成绩与设置。现在每次启动后端时生成一次性随机令牌，通过启动环境
/// 变量注入后端，并附加到每个 HTTP 请求头 / WebSocket 握手上。
///
/// 令牌只存在于两个进程的内存中（后端另存一份 0600 文件供手动启动时复用），
/// 不走网络明文传输、不进 URL（WebSocket 除外，见 websocket_service 注释）。
class ApiToken {
  ApiToken._();

  static const String headerName = 'X-GradeMonitor-Token';

  static String? _value;

  /// 当前令牌；未初始化时返回空字符串（后端会拒绝，故应先 ensure）。
  static String get value => _value ?? '';

  /// 生成新令牌并缓存（ASCII，适合放 HTTP 头与启动环境变量）
  static String generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    final token = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    _value = token;
    return token;
  }

  /// 从既有值装载（例如复用后端已写入的 token 文件时）
  static void adopt(String token) {
    if (token.trim().isNotEmpty) _value = token.trim();
  }

  static bool get hasValue => (_value ?? '').isNotEmpty;
}
