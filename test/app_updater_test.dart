import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:story_reader/update/app_updater.dart';

/// Giả lập nền path_provider thuần Dart (KHÔNG dùng TestWidgetsFlutterBinding:
/// binding chặn HTTP thật, làm hỏng các test tải file qua server loopback).
class FakePathProvider extends PathProviderPlatform {
  final String tempPath;
  FakePathProvider(this.tempPath);

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  late HttpServer server;
  late Directory tmp;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    tmp = await Directory.systemTemp.createTemp('apk_dl_test');
    // Trỏ thư mục tạm về tmp của riêng test (cleanupLeftoverApk dùng nó).
    PathProviderPlatform.instance = FakePathProvider(tmp.path);
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test('downloadApk ghi đủ file và báo tiến độ tới byte cuối', () async {
    // File APK = ZIP: bắt đầu bằng chữ ký 'PK' (downloadApk kiểm tra).
    final data = Uint8List.fromList([
      0x50,
      0x4B,
      ...List.generate(299998, (i) => i % 251),
    ]);
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

  test(
    'cleanupLeftoverApk xoá thư mục update còn sót từ lần cài trước',
    () async {
      final updateDir = Directory(p.join(tmp.path, 'update'))
        ..createSync(recursive: true);
      File(p.join(updateDir.path, 'story_reader_update.apk'))
          .writeAsStringSync('apk giả');

      await AppUpdater.cleanupLeftoverApk();

      expect(updateDir.existsSync(), false);
    },
  );

  test('cleanupLeftoverApk không lỗi khi chưa có file nào để xoá', () async {
    await AppUpdater.cleanupLeftoverApk();
    await AppUpdater.cleanupLeftoverApk();
  });

  test('downloadApk: stream chunked kết thúc sớm + expectedSize lệch → ném lỗi, xoá file', () async {
    // Server gửi 500 byte KHÔNG khai báo content-length (HTTP/1.1 → chunked)
    // rồi kết thúc bình thường: stream không báo lỗi nhưng file cụt so với
    // dung lượng GitHub — bắt buộc phải bắt được qua expectedSize.
    final data = Uint8List.fromList(List.generate(500, (i) => 0x41));
    server.listen((req) async {
      await req.response.addStream(Stream.value(data));
      await req.response.close();
    });
    final path = p.join(tmp.path, 'app.apk');
    await expectLater(
      AppUpdater.downloadApk(
        'http://127.0.0.1:${server.port}/app.apk',
        path,
        (_, _) {},
        expectedSize: 60 * 1024 * 1024,
      ),
      throwsException,
    );
    expect(await File(path).exists(), false);
  });

  test(
    'downloadApk: file không phải APK (thiếu chữ ký PK) → ném lỗi, xoá file',
    () async {
      final data = Uint8List.fromList(List.generate(1000, (i) => 0x41));
      server.listen((req) async {
        req.response.contentLength = data.length;
        await req.response.addStream(Stream.value(data));
        await req.response.close();
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
    },
  );

  test('downloadApk: file APK hợp lệ (PK, đủ size) → tải ok', () async {
    final data = Uint8List.fromList([
      0x50,
      0x4B,
      ...List.generate(1000, (i) => 0x41),
    ]);
    server.listen((req) async {
      req.response.contentLength = data.length;
      await req.response.addStream(Stream.value(data));
      await req.response.close();
    });
    final path = p.join(tmp.path, 'app.apk');
    final out = await AppUpdater.downloadApk(
      'http://127.0.0.1:${server.port}/app.apk',
      path,
      (_, _) {},
      expectedSize: data.length,
    );
    expect(out, path);
    expect(await File(path).exists(), true);
  });
}
