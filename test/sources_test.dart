import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/sources/registry.dart';

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
    expect(seeded.loginUrl, 'https://dammyy.cc/login',
        reason: 'seed search không được mất trang đăng nhập');
    // Nguồn không khai báo đăng nhập: null, không gây lỗi.
    final plain = SourceAdapter.fromJson({'domain': 'x.com'});
    expect(plain.loginUrl, null);
  });
}
