import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:story_reader/update/app_updater.dart';

void main() {
  late HttpServer server;
  late Directory tmp;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    tmp = await Directory.systemTemp.createTemp('apk_dl_test');
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test('downloadApk ghi đủ file và báo tiến độ tới byte cuối', () async {
    final data = Uint8List.fromList(
      List.generate(300000, (i) => i % 251),
    );
    server.listen((req) async {
      req.response.contentLength = data.length;
      await req.response.addStream(Stream.value(data));
      await req.response.close();
    });
    final path = p.join(tmp.path, 'app.apk');
    var last = 0;
    int? total;
    final out = await AppUpdater.downloadApk(
      'http://127.0.0.1:${server.port}/app.apk',
      path,
      (r, t) {
        last = r;
        total = t;
      },
    );
    expect(out, path);
    expect(await File(path).length(), data.length);
    expect(last, data.length);
    expect(total, data.length);
  });

  test('server trả lỗi thì ném lỗi và xoá file lẻ', () async {
    server.listen((req) async {
      req.response.statusCode = 404;
      await req.response.close();
    });
    final path = p.join(tmp.path, 'app.apk');
    await expectLater(
      AppUpdater.downloadApk(
        'http://127.0.0.1:${server.port}/x.apk',
        path,
        (_, _) {},
      ),
      throwsException,
    );
    expect(await File(path).exists(), false);
  });

  test('mất kết nối giữa chừng thì ném lỗi và xoá file lẻ', () async {
    server.listen((req) async {
      try {
        // contentLength khai báo nhiều hơn số byte gửi rồi ngắt: client nhận
        // lỗi "đóng kết nối giữa chừng" thay vì kết thúc bình thường.
        req.response.contentLength = 1000000;
        req.response.add([1, 2, 3]);
        await req.response.flush();
        await req.response.close();
      } catch (_) {}
    });
    final path = p.join(tmp.path, 'app.apk');
    await expectLater(
      AppUpdater.downloadApk(
        'http://127.0.0.1:${server.port}/app.apk',
        path,
        (_, _) {},
      ),
      throwsException,
    );
    expect(await File(path).exists(), false);
  });

  test('nghẽn mạng quá lâu thì hủy bằng TimeoutException', () async {
    server.listen((req) async {
      req.response.contentLength = 1000000;
      await req.response.addStream(Stream.value([1, 2, 3]));
      // Không close, không gửi thêm: giữ kết nối treo để chờ watchdog.
    });
    final path = p.join(tmp.path, 'app.apk');
    await expectLater(
      AppUpdater.downloadApk(
        'http://127.0.0.1:${server.port}/app.apk',
        path,
        (_, _) {},
        stallTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await File(path).exists(), false);
  });
}
