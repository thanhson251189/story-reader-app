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

  static const personal = bool.fromEnvironment('PERSONAL');

  // Adapter cài từ bản cũ chưa có searchUrl: app seed sẵn cấu hình tìm kiếm
  // cho nguồn chính thức để bản cập nhật app là tìm được ngay, không bắt
  // người dùng cài lại nguồn. Adapter remote định nghĩa searchUrl sẽ thắng.
  static const _builtinSearch = <String, Map<String, dynamic>>{
    'truyendich.space': {
      'searchUrl': 'https://truyendich.space/tim-kiem?q={query}',
      'selectors': {
        'searchList': "a[href^='/doc-truyen/']",
        'searchTitle': 'h3',
      },
    },
    'vi.wikisource.org': {
      'searchUrl': 'https://vi.wikisource.org/w/index.php?title=Special:Search&search={query}&fulltext=1',
      'selectors': {
        'searchList': 'ul.mw-search-results li.mw-search-result',
        'searchTitle': '.mw-search-result-heading a',
      },
    },
  };

  static SourceAdapter withBuiltinSearch(SourceAdapter a) {
    if (a.searchUrl != null) return a;
    final b = _builtinSearch[a.domain];
    if (b == null) return a;
    return a.withSearch(
      b['searchUrl'] as String,
      Map<String, String>.from(b['selectors'] as Map),
    );
  }

  static const defaultIndexUrl =
      'https://raw.githubusercontent.com/thanhson251189/story-reader-sources/main/sources/index.json';

  Future<String> indexUrl() async =>
      await db.getSetting('registryUrl') ?? (personal ? defaultIndexUrl : '');

  Future<void> setIndexUrl(String url) => db.setSetting('registryUrl', url);

  Future<List<SourceEntry>> loadIndex() async {
    final url = await indexUrl();
    if (url.isEmpty) return [];
    String? raw;
    try {
      final res = await http
          .get(Uri.parse(url))
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

  Future<String> appVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  static int compareVersions(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  SourceAdapter? installed(String domain) => installedIn(adapters, domain);

  static SourceAdapter? installedIn(AdapterRepository adapters, String domain) {
    for (final a in adapters.all) {
      if (a.domain == domain) return a;
    }
    return null;
  }

  static List<SourceEntry> pendingUpdates(
    List<SourceEntry> entries,
    AdapterRepository adapters,
    String appVersion,
  ) => entries.where((e) {
    final inst = installedIn(adapters, e.domain);
    return inst != null &&
        e.version > inst.version &&
        compareVersions(e.minAppVersion, appVersion) <= 0;
  }).toList();

  Future<Map<String, String>> nameOverrides() async => Map<String, String>.from(
    jsonDecode(await db.getSetting('adapterNames') ?? '{}') as Map,
  );

  Future<void> setName(String domain, String name) async {
    final names = await nameOverrides();
    names[domain] = name;
    await db.setSetting('adapterNames', jsonEncode(names));
  }

  static Map<String, dynamic> savedWithout(
    Map<String, dynamic> saved,
    String domain,
  ) => Map.fromEntries(
    saved.entries.where((e) => (e.value as Map)['domain'] != domain),
  );

  Future<void> uninstall(String domain) async {
    final saved = Map<String, dynamic>.from(
      jsonDecode(await db.getSetting('installedAdapters') ?? '{}') as Map,
    );
    await db.setSetting(
      'installedAdapters',
      jsonEncode(savedWithout(saved, domain)),
    );
    final names = await nameOverrides();
    if (names.remove(domain) != null) {
      await db.setSetting('adapterNames', jsonEncode(names));
    }
    adapters.remove(domain);
  }

  Future<void> install(SourceEntry e) async {
    final res = await http
        .get(Uri.parse(e.url))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    adapters.mergeRemote([withBuiltinSearch(SourceAdapter.fromJson(json))]);
    final saved = Map<String, dynamic>.from(
      jsonDecode(await db.getSetting('installedAdapters') ?? '{}') as Map,
    );
    saved[e.id] = json;
    await db.setSetting('installedAdapters', jsonEncode(saved));
  }

  static Future<void> restoreInstalled(
    AppDb db,
    AdapterRepository adapters,
  ) async {
    final raw = await db.getSetting('installedAdapters');
    if (raw == null) return;
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    adapters.mergeRemote(
      saved.values
          .map(
            (e) => withBuiltinSearch(
              SourceAdapter.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          )
          .toList(),
    );
  }
}
