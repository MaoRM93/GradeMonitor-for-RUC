import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grademonitor/core/service/update_service.dart';

void main() {
  late Directory tempDir;
  late HttpServer server;
  late Uint8List payload;
  var rangeRequests = <String>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('update-download-test-');
    payload = Uint8List.fromList(
      List<int>.generate(128 * 1024, (index) => index % 251),
    );
    rangeRequests = <String>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) rangeRequests.add(range);
      final offset = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final body = payload.sublist(offset);
      if (offset > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $offset-${payload.length - 1}/${payload.length}',
        );
      }
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tempDir.delete(recursive: true);
  });

  ReleaseAsset asset() => ReleaseAsset(
    name: 'update.zip',
    url: 'http://${server.address.host}:${server.port}/update.zip',
    size: payload.length,
  );

  test('downloads a release asset and reports completion', () async {
    var lastReceived = 0;
    var lastTotal = 0;

    final path = await UpdateService().downloadRelease(
      asset(),
      destinationDirectory: tempDir,
      onProgress: (received, total) {
        lastReceived = received;
        lastTotal = total;
      },
    );

    expect(await File(path).readAsBytes(), payload);
    expect(lastReceived, payload.length);
    expect(lastTotal, payload.length);
    expect(rangeRequests, isEmpty);
  });

  test('resumes an existing partial download with a Range request', () async {
    final split = payload.length ~/ 3;
    final part = File(
      '${tempDir.path}${Platform.pathSeparator}update.zip.part',
    );
    await part.writeAsBytes(payload.sublist(0, split));

    final path = await UpdateService().downloadRelease(
      asset(),
      destinationDirectory: tempDir,
    );

    expect(await File(path).readAsBytes(), payload);
    expect(rangeRequests, ['bytes=$split-']);
    expect(part.existsSync(), isFalse);
  });
}
