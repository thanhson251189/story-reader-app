import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/sources/registry.dart';

/// Test lớp registry với DB thật (FFI) và server loopback giả lập HTTP:
/// settings hỏng không được làm chết đường khởi động app, cache index không
/// bị body lạ đè mất.
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('restoreInstalled với settings hỏng không ném, app vẫn mở được', () async {
    final db = AppDb(fileName: 'registry_restore_bad_test.db');
    await db.setSetting('installedAdapters', '{"x": không phải json');
    final repo = AdapterRepository([]);
    await SourceRegistry.restoreInstalled(db, repo);
    expect(repo.all, isEmpty);
  });

  test('restoreInstalled một nguồn hỏng không chặn các nguồn lành', () async {
    final db = AppDb(fileName: 'registry_restore_mixed_test.db');
    await db.setSetting('installedAdapters', jsonEncode({
      'good': {
        'domain': 'good.com',
        'version': 1,
        'selectors': {'content': '#c'},
        'removeSelectors': <String>[],
        'textCleanup': <Map<String, String>>[],
      },
      'bad': 42,
    }));
    final repo = AdapterRepository([]);
    await SourceRegistry.restoreInstalled(db, repo);
    expect(repo.forUrl('https://good.com/x'), isNotNull);
    expect(repo.forUrl('https://bad.com/x'), isNull);
  });

  test('install với settings cũ hỏng vẫn cài được nguồn mới', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = utf8.encode(jsonEncode({
        'domain': 'new.com',
        'version': 3,
        'selectors': {'content': '#c'},
        'removeSelectors': <String>[],
        'textCleanup': <Map<String, String>>[],
      }));
      req.response.headers.contentType = ContentType.json;
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
    final db = AppDb(fileName: 'registry_install_bad_test.db');
    await db.setSetting('installedAdapters', '{json cũ hỏng');
    final repo = AdapterRepository([]);
    final registry = SourceRegistry(db, repo);
    await registry.install(
      SourceEntry(
        id: 'new',
        name: 'Nguồn mới',
        domain: 'new.com',
        version: 3,
        minAppVersion: '0.0.0',
        url: 'http://127.0.0.1:${server.port}/adapter.json',
      ),
    );
    expect(repo.forUrl('https://new.com/chuong-1'), isNotNull);
    final saved =
        jsonDecode(await db.getSetting('installedAdapters') as String) as Map;
    expect(saved['new'], isNotNull, reason: 'settings hỏng được thay bằng bản tốt');
  });

  test('loadIndex body hỏng không đè cache tốt', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = utf8.encode('NOT_JSON — proxy chặn trả HTML');
      req.response.headers.contentType = ContentType.text;
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
    final db = AppDb(fileName: 'registry_index_bad_test.db');
    await db.setSetting('registryUrl', 'http://127.0.0.1:${server.port}/index.json');
    final cacheBody = jsonEncode({
      'sources': [
        {
          'id': 'g',
          'domain': 'g.com',
          'version': 1,
          'url': 'https://g.com/adapter.json',
        },
      ],
    });
    await db.setSetting('registryIndexCache', cacheBody);
    final registry = SourceRegistry(db, AdapterRepository([]));
    final entries = await registry.loadIndex();
    expect(entries, hasLength(1), reason: 'body mới hỏng thì dùng cache cũ');
    expect(entries.first.domain, 'g.com');
    expect(
      await db.getSetting('registryIndexCache'),
      cacheBody,
      reason: 'body hỏng không được ghi đè cache tốt',
    );
  });

  test('loadIndex body tốt thì ghi đè cache', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = utf8.encode(jsonEncode({
        'sources': [
          {
            'id': 'f',
            'domain': 'fresh.com',
            'version': 2,
            'url': 'https://fresh.com/adapter.json',
          },
        ],
      }));
      req.response.headers.contentType = ContentType.json;
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
    final db = AppDb(fileName: 'registry_index_fresh_test.db');
    await db.setSetting('registryUrl', 'http://127.0.0.1:${server.port}/index.json');
    await db.setSetting('registryIndexCache', '{"sources": []}');
    final registry = SourceRegistry(db, AdapterRepository([]));
    final entries = await registry.loadIndex();
    expect(entries.first.domain, 'fresh.com');
    expect(
      await db.getSetting('registryIndexCache'),
      contains('fresh.com'),
      reason: 'body tốt được giữ vào cache cho lần mất mạng sau',
    );
  });
}
