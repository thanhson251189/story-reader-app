import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/sources/registry.dart';
import 'package:story_reader/sources/source_login_screen.dart';

SourceAdapter adapter(String domain, int version) => SourceAdapter(
  domain: domain,
  version: version,
  selectors: const {'content': '#c'},
  removeSelectors: const [],
  textCleanup: const [],
);

SourceEntry entry(String domain, int version, {String minApp = '0.0.0'}) =>
    SourceEntry(
      id: domain,
      name: domain,
      domain: domain,
      version: version,
      minAppVersion: minApp,
      url: 'https://example.com/$domain.json',
    );

SourceEntry named(String domain, String name, {bool adult = false}) =>
    SourceEntry(
      id: domain,
      name: name,
      domain: domain,
      version: 1,
      minAppVersion: '0.0.0',
      url: 'https://example.com/$domain.json',
      adult: adult,
    );

void main() {
  test('AdapterRepository.remove gỡ đúng nguồn', () {
    final repo = AdapterRepository([adapter('a.com', 1), adapter('b.com', 2)]);
    repo.remove('a.com');
    expect(repo.all.map((a) => a.domain), ['b.com']);
    expect(repo.forUrl('https://a.com/x'), null);
  });

  test('pendingUpdates chỉ lấy nguồn đã cài có bản mới hơn', () {
    final repo = AdapterRepository([adapter('a.com', 1), adapter('b.com', 2)]);
    final entries = [entry('a.com', 2), entry('b.com', 2), entry('c.com', 9)];
    expect(
      SourceRegistry.pendingUpdates(
        entries,
        repo,
        '1.0.6',
      ).map((e) => e.domain),
      ['a.com'],
    );
  });

  test('pendingUpdates bỏ nguồn đòi app mới hơn', () {
    final repo = AdapterRepository([adapter('a.com', 1)]);
    final entries = [entry('a.com', 2, minApp: '9.0.0')];
    expect(SourceRegistry.pendingUpdates(entries, repo, '1.0.6'), isEmpty);
  });

  test('savedWithout gỡ json theo domain, giữ nguồn khác', () {
    final saved = {
      'x': {'domain': 'a.com', 'version': 1},
      'y': {'domain': 'b.com', 'version': 2},
    };
    final left = SourceRegistry.savedWithout(saved, 'a.com');
    expect(left.keys, ['y']);
    expect(saved.keys, ['x', 'y'], reason: 'không mutate map gốc');
  });

  test('loginUrl đọc từ json và withSearch giữ nguyên', () {
    final a = SourceAdapter.fromJson({
      'domain': 'dammyy.cc',
      'selectors': {'content': '.chapter-content'},
      'searchUrl': 'https://dammyy.cc/tim-kiem?search={query}',
      'loginUrl': 'https://dammyy.cc/login',
    });
    expect(a.loginUrl, 'https://dammyy.cc/login');
    final seeded = a.withSearch(
      'https://dammyy.cc/tim-kiem?search={query}',
      const {'searchList': '.card'},
    );
    expect(
      seeded.loginUrl,
      'https://dammyy.cc/login',
      reason: 'seed search không được mất trang đăng nhập',
    );
    // Nguồn không khai báo đăng nhập: null, không gây lỗi.
    final plain = SourceAdapter.fromJson({'domain': 'x.com'});
    expect(plain.loginUrl, null);
  });

  test(
    'loadAdapterNames đọc json hợp lệ, hỏng thì trả rỗng thay vì sập',
    () async {
      final db = _FakeDb();
      expect(await loadAdapterNames(db), isEmpty);

      db.settings['adapterNames'] = '{"a.com":"Nguồn A","b.com":"Nguồn B"}';
      expect(await loadAdapterNames(db), {
        'a.com': 'Nguồn A',
        'b.com': 'Nguồn B',
      });

      db.settings['adapterNames'] = '{json hỏng';
      expect(await loadAdapterNames(db), isEmpty);
    },
  );

  test('namesFromCache: tên trong danh sách, tên người dùng đổi thắng', () {
    const cache =
        '{"sources":[{"id":"td","name":"TruyenDich","domain":"truyendich.us","url":"https://x"}]}';
    final names = SourceRegistry.namesFromCache(cache, {
      'truyendich.us': 'Tên của tôi',
    });
    expect(SourceRegistry.labelFor('truyendich.us', names), 'Tên của tôi');
    expect(SourceRegistry.labelFor('khac.com', names), 'khac.com');
    expect(
      SourceRegistry.labelFor(
        'truyendich.us',
        SourceRegistry.namesFromCache(cache, const {}),
      ),
      'TruyenDich',
    );
  });

  test('SourceEntry đọc cờ 18+ từ index, thiếu thì mặc định false', () {
    final adult = SourceEntry.fromJson({
      'id': 'a',
      'name': 'A',
      'domain': 'a.com',
      'url': 'https://x',
      'adult': true,
    });
    expect(adult.adult, true);
    final plain = SourceEntry.fromJson({
      'id': 'b',
      'name': 'B',
      'domain': 'b.com',
      'url': 'https://x',
    });
    expect(plain.adult, false);
  });

  test('foldName bỏ dấu để tên tiếng Việt xếp đúng thứ tự', () {
    expect(SourceRegistry.foldName('Đam Mỹ'), 'dam my');
    expect(SourceRegistry.foldName('Truyện Kể'), 'truyen ke');
    final names = ['Zeta', 'Đam Mỹ', 'Ánh Dương', 'Bình Minh']
      ..sort((a, b) => SourceRegistry.foldName(
        a,
      ).compareTo(SourceRegistry.foldName(b)));
    expect(names, ['Ánh Dương', 'Bình Minh', 'Đam Mỹ', 'Zeta']);
  });

  test('sortedForDisplay: đã cài trước, mỗi nhóm xếp theo tên, tên đổi thắng', () {
    final repo = AdapterRepository([
      adapter('b.com', 1),
      adapter('d.com', 1),
    ]);
    final entries = [
      named('a.com', 'Zeta'),
      named('b.com', 'Đam Mỹ'),
      named('c.com', 'Ánh Dương'),
      named('d.com', 'Bình Minh'),
      named('e.com', 'Truyện Kể'),
    ];
    final sorted = SourceRegistry.sortedForDisplay(entries, {
      'b.com': 'Ấn Tượng',
    }, repo);
    expect(sorted.map((e) => e.domain), [
      'b.com', // đã cài, tên đổi "Ấn Tượng"
      'd.com', // đã cài
      'c.com', // chưa cài, Ánh Dương
      'e.com', // chưa cài, Truyện Kể
      'a.com', // chưa cài, Zeta
    ]);
    expect(
      SourceRegistry.displayName(sorted.first, {'b.com': 'Ấn Tượng'}),
      'Ấn Tượng',
    );
  });
}

class _FakeDb extends AppDb {
  final settings = <String, String>{};

  @override
  Future<String?> getSetting(String key) async => settings[key];
}
