import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../adapters/adapter_repository.dart';
import '../core/models.dart';
import '../data/app_db.dart';

class SourceEntry {
  final String id;
  final String name;
  final String domain;
  final int version;
  final String minAppVersion;
  final String url;

  SourceEntry({
    required this.id,
    required this.name,
    required this.domain,
    required this.version,
    required this.minAppVersion,
    required this.url,
  });

  factory SourceEntry.fromJson(Map<String, dynamic> j) => SourceEntry(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        domain: j['domain'] as String,
        version: (j['version'] as num?)?.toInt() ?? 1,
        minAppVersion: j['minAppVersion'] as String? ?? '0.0.0',
        url: j['url'] as String,
      );
}

class SourceRegistry {
  final AppDb db;
  final AdapterRepository adapters;

  SourceRegistry(this.db, this.adapters);

  static const defaultIndexUrl =
      'https://raw.githubusercontent.com/thanhson251189/story-reader-sources/main/sources/index.json';

  Future<String> indexUrl() async =>
      await db.getSetting('registryUrl') ?? defaultIndexUrl;

  Future<void> setIndexUrl(String url) => db.setSetting('registryUrl', url);

  Future<List<SourceEntry>> loadIndex() async {
    String? raw;
    try {
      final res = await http
          .get(Uri.parse(await indexUrl()))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        raw = res.body;
        await db.setSetting('registryIndexCache', raw);
      }
    } catch (_) {}
    raw ??= await db.getSetting('registryIndexCache');
    if (raw == null) return [];
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (j['sources'] as List? ?? [])
        .map((e) => SourceEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<String> appVersion() async => (await PackageInfo.fromPlatform()).version;

  static int compareVersions(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  SourceAdapter? installed(String domain) {
    for (final a in adapters.all) {
      if (a.domain == domain) return a;
    }
    return null;
  }

  Future<void> install(SourceEntry e) async {
    final res =
        await http.get(Uri.parse(e.url)).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    adapters.mergeRemote([SourceAdapter.fromJson(json)]);
    final saved = Map<String, dynamic>.from(
        jsonDecode(await db.getSetting('installedAdapters') ?? '{}') as Map);
    saved[e.id] = json;
    await db.setSetting('installedAdapters', jsonEncode(saved));
  }

  static Future<void> restoreInstalled(
      AppDb db, AdapterRepository adapters) async {
    final raw = await db.getSetting('installedAdapters');
    if (raw == null) return;
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    adapters.mergeRemote(saved.values
        .map((e) => SourceAdapter.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList());
  }
}