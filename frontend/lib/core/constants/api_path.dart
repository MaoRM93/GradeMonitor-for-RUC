/// 后端 API 端点定义
class ApiPath {
  ApiPath._();

  static const String baseUrl = 'http://127.0.0.1:18923';
  static const String wsUrl = 'ws://127.0.0.1:18923/ws/events';

  // Auth
  static const String login = '/api/login';

  // Data
  static const String grades = '/api/grades';
  static const String gradesLatestChange = '/api/grades/latest-change';
  static const String rank = '/api/rank';

  // Settings
  static const String settings = '/api/settings';

  // Monitor
  static const String monitorStatus = '/api/monitor/status';
  static const String monitorStart = '/api/monitor/start';
  static const String monitorStop = '/api/monitor/stop';
  static const String monitorRestart = '/api/monitor/restart';

  // Notification
  static const String notificationTest = '/api/notification/test';
  static const String notificationPreview = '/api/notification/preview';

  // Dev Tools
  static const String devQueryOnce = '/api/dev/query-once';
  static const String devClearCache = '/api/dev/clear-cache';
  static const String devClearAllData = '/api/dev/clear-all-data';
  static const String devOpenLogDir = '/api/dev/open-log-dir';

  // Welcome
  static const String welcomeStatus = '/api/welcome/status';
  static const String welcomeComplete = '/api/welcome/complete';
}
