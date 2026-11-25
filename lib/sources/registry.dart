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
  final bool adult;

  SourceEntry({
    required this.id,
    required this.name,
    required this.domain,
    required this.version,
    required this.minAppVersion,
    required this.url,
    this.adult = false,
  });

  factory SourceEntry.fromJson(Map<String, dynamic> j) => SourceEntry(
    id: j['id'] as String,
    name: j['name'] as String? ?? j['id'] as String,
    domain: j['domain'] as String,
    version: (j['version'] as num?)?.toInt() ?? 1,
    minAppVersion: j['minAppVersion'] as String? ?? '0.0.0',
    url: j['url'] as String,
    adult: j['adult'] as bool? ?? false,
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
    'truyendich.us': {
      'searchUrl': 'https://truyendich.us/tim-kiem?q={query}',
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

  /// Domain nguồn 18+ đã biết (lưu từ index lúc tải/cài nguồn) — cần cho bộ
  /// lọc ẩn nội dung khi app mở offline, lúc đó không có index để đọc.
  static const adultDomainsKey = 'adultDomains';
  static const hideAdultKey = 'hideAdult';

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
      if (res.statusCode == 200) raw = res.body;
    } catch (_) {}
    if (raw != null) {
      final entries = parseIndex(raw);
      if (entries != null) {
        // Chỉ ghi đè cache khi body đọc được: proxy chặn trả HTML mà đè mất
        // cache tốt thì lần mất mạng sau không còn danh sách nguồn nào.
        await db.setSetting('registryIndexCache', raw);
        await _saveAdultDomains(entries);
        return entries;
      }
      raw = null;
    }
    final cached = await db.getSetting('registryIndexCache');
    final entries = cached == null
        ? const <SourceEntry>[]
        : (parseIndex(cached) ?? const <SourceEntry>[]);
    if (entries.isNotEmpty) await _saveAdultDomains(entries);
    return entries;
  }

  Future<void> _saveAdultDomains(List<SourceEntry> entries) async {
    final domains = {
      for (final e in entries)
        if (e.adult) e.domain.toLowerCase(),
    }.toList()..sort();
    final raw = jsonEncode(domains);
    if (await db.getSetting(adultDomainsKey) == raw) return;
    await db.setSetting(adultDomainsKey, raw);
  }

  static Future<Set<String>> adultDomains(AppDb db) async {
    final raw = await db.getSetting(adultDomainsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        return {
          for (final d in jsonDecode(raw) as List)
            if (d is String && d.isNotEmpty) d.toLowerCase(),
        };
      } catch (_) {
        // File hỏng: rơi xuống đọc index cache bên dưới.
      }
    }
    // Bản cũ chưa lưu riêng: đọc cờ adult từ cache index để bộ lọc có tác
    // dụng ngay cả khi chưa tải lại index.
    final out = <String>{};
    final entries =
        parseIndex(await db.getSetting('registryIndexCache') ?? '') ??
        const <SourceEntry>[];
    for (final e in entries) {
      if (e.adult) out.add(e.domain.toLowerCase());
    }
    return out;
  }

  static Future<bool> hideAdultEnabled(AppDb db) async =>
      (await db.getSetting(hideAdultKey) ?? '0') == '1';

  /// [host] (hoặc domain adapter) có thuộc nguồn 18+ không. So cả subdomain
  /// vì adapter khai domain gốc còn link truyện có thể nằm ở www/m.
  static bool isAdultHost(String? host, Set<String> adultDomains) {
    if (host == null || host.isEmpty) return false;
    final h = host.toLowerCase();
    return adultDomains.any((d) => h == d || h.endsWith('.$d'));
  }

  static bool isAdultStory(
    String storyUrl,
    Set<String> adultDomains,
    AdapterRepository adapters,
  ) {
    final domain =
        adapters.forUrl(storyUrl)?.domain ?? Uri.tryParse(storyUrl)?.host ?? '';
    return isAdultHost(domain, adultDomains);
  }

  /// Body JSON danh sách nguồn → danh sách entry; hỏng thì trả null thay vì
  /// ném (người gọi chỉ cần thấy "không tải được danh sách" là đủ).
  /// Tên dễ đọc: bản người dùng đổi tên thắng tên trong danh sách nguồn.
  /// Không có cả hai thì nơi gọi hiện tên miền.
  static Map<String, String> namesFromCache(
    String? indexCache,
    Map<String, String> overrides,
  ) {
    final fromIndex = <String, String>{};
    if (indexCache != null && indexCache.isNotEmpty) {
      for (final e in parseIndex(indexCache) ?? const <SourceEntry>[]) {
        final n = e.name.trim();
        if (n.isNotEmpty) fromIndex[e.domain] = n;
      }
    }
    return {...fromIndex, ...overrides};
  }

  static String labelFor(String domain, Map<String, String> names) {
    final n = names[domain]?.trim();
    if (n == null || n.isEmpty) return domain;
    return n;
  }

  static String displayName(SourceEntry e, Map<String, String> names) {
    final n = names[e.domain]?.trim();
    return (n == null || n.isEmpty) ? e.name.trim() : n;
  }

  // Bỏ dấu tiếng Việt để sắp xếp theo tên: so codepoint thì "Đam Mỹ" rơi sau
  // "Z" và mọi tên có dấu xếp lộn xộn.
  static const _foldGroups = {
    'a': 'áàảãạăắằẳẵặâấầẩẫậ',
    'e': 'éèẻẽẹêếềểễệ',
    'i': 'íìỉĩị',
    'o': 'óòỏõọôốồổỗộơớờởỡợ',
    'u': 'úùủũụưứừửữự',
    'y': 'ýỳỷỹỵ',
    'd': 'đ',
  };

  static String foldName(String s) {
    var t = s.toLowerCase();
    _foldGroups.forEach((plain, chars) {
      for (final c in chars.split('')) {
        t = t.replaceAll(c, plain);
      }
    });
    return t;
  }

  /// Nguồn đã cài lên trước, mỗi nhóm xếp theo tên hiển thị (bỏ dấu).
  static List<SourceEntry> sortedForDisplay(
    Iterable<SourceEntry> entries,
    Map<String, String> names,
    AdapterRepository adapters,
  ) {
    final list = List.of(entries);
    final keys = {
      for (final e in list) e.domain: foldName(displayName(e, names)),
    };
    final installed = {
      for (final e in list) e.domain: installedIn(adapters, e.domain) != null,
    };
    list.sort((a, b) {
      final ai = installed[a.domain]!;
      final bi = installed[b.domain]!;
      if (ai != bi) return ai ? -1 : 1;
      final d = keys[a.domain]!.compareTo(keys[b.domain]!);
      return d != 0 ? d : a.domain.compareTo(b.domain);
    });
    return list;
  }

  static List<SourceEntry>? parseIndex(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (j['sources'] as List? ?? [])
          .map((e) => SourceEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return null;
    }
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

  /// Đọc bản đồ adapter đã cài từ settings; dữ liệu hỏng (JSON sai) trả về
  /// rỗng thay vì ném — restoreInstalled chạy trước runApp, ném ở đây là app
  /// không bao giờ mở lại được cho tới khi người dùng xoá dữ liệu. Map trả
  /// về phải chỉnh sửa được: install() ghi thêm nguồn mới vào nó.
  static Map<String, dynamic> readSaved(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> uninstall(String domain) async {
    final saved = readSaved(await db.getSetting('installedAdapters'));
    await db.setSetting(
      'installedAdapters',
      jsonEncode(savedWithout(saved, domain)),
    );
    final names = await nameOverrides();
    if (names.remove(domain) != null) {
      await db.setSetting('adapterNames', jsonEncode(names));
    }
    await _setAdultDomain(domain, false);
    adapters.remove(domain);
  }

  Future<void> _setAdultDomain(String domain, bool adult) async {
    final domains = await adultDomains(db);
    final changed = adult
        ? domains.add(domain.toLowerCase())
        : domains.remove(domain.toLowerCase());
    if (!changed) return;
    await db.setSetting(adultDomainsKey, jsonEncode(domains.toList()..sort()));
  }

  Future<void> install(SourceEntry e) async {
    final res = await http
        .get(Uri.parse(e.url))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    adapters.mergeRemote([withBuiltinSearch(SourceAdapter.fromJson(json))]);
    final saved = readSaved(await db.getSetting('installedAdapters'));
    saved[e.id] = json;
    await db.setSetting('installedAdapters', jsonEncode(saved));
    await _setAdultDomain(e.domain, e.adult);
  }

  /// Chạy ngầm lúc mở app: tải index (có cache dự phòng), cài sẵn các bản
  /// cập nhật nguồn đã cài. Lỗi từng nguồn bỏ qua — người dùng không cần biết
  /// trừ khi có gì thực sự đổi; trả về số nguồn đã cập nhật để báo một dòng.
  Future<int> autoUpdateInstalled() async {
    final entries = await loadIndex();
    if (entries.isEmpty) return 0;
    final version = await appVersion();
    final updates = pendingUpdates(entries, adapters, version);
    var ok = 0;
    for (final e in updates) {
      try {
        await install(e);
        ok++;
      } catch (_) {}
    }
    return ok;
  }

  static Future<void> restoreInstalled(
    AppDb db,
    AdapterRepository adapters,
  ) async {
    final saved = readSaved(await db.getSetting('installedAdapters'));
    final loaded = <SourceAdapter>[];
    for (final e in saved.values) {
      try {
        loaded.add(
          withBuiltinSearch(
            SourceAdapter.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );
      } catch (_) {
        // Một nguồn hỏng không được chặn các nguồn lành còn lại.
      }
    }
    adapters.mergeRemote(loaded);
  }
}
