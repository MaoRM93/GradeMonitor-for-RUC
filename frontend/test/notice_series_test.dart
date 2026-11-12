import 'package:flutter_test/flutter_test.dart';
import 'package:grademonitor/core/service/update_service.dart';

void main() {
  test('114 号段判定只看首段', () {
    expect(UpdateService.isNoticeSeriesTag('114.100'), isTrue);
    expect(UpdateService.isNoticeSeriesTag('114.513'), isTrue);
    expect(UpdateService.isNoticeSeriesTag('v114.600'), isTrue);
    // 末位 114 不属于号段，仍要照常当版本号
    expect(UpdateService.isNoticeSeriesTag('108.1.0.114'), isFalse);
    expect(UpdateService.isNoticeSeriesTag('108.1.0.103'), isFalse);
    expect(UpdateService.isNoticeSeriesTag('27G36'), isFalse);
    expect(UpdateService.isNoticeSeriesTag(''), isFalse);
  });

  test('号段内 513/514/515 是专用页面，其余才是广播', () {
    expect(UpdateService.isBroadcastTag('114.100'), isTrue);
    expect(UpdateService.isBroadcastTag('114.999'), isTrue);
    expect(UpdateService.isBroadcastTag('114.513'), isFalse);
    expect(UpdateService.isBroadcastTag('114.514'), isFalse);
    expect(UpdateService.isBroadcastTag('114.515'), isFalse);
    expect(UpdateService.isBroadcastTag('108.1.0.114'), isFalse);
  });
}
