import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';

void main() {
  test('SourceAdapter parse and match domain', () {
    final a = SourceAdapter.fromJson({
      'id': 'test',
      'domain': 'example.com',
      'version': 2,
      'selectors': {'content': '#content'},
      'removeSelectors': ['script'],
      'textCleanup': [
        {'pattern': 'ADS', 'replacement': ''}
      ],
    });
    expect(a.matches('https://example.com/chuong-1'), true);
    expect(a.matches('https://sub.example.com/x'), true);
    expect(a.matches('https://other.com/x'), false);
    expect(a.clean('hello ADS world'), 'hello  world');
  });

  test('ChapterContent roundtrip', () {
    final c = ChapterContent.fromJson({
      'url': 'https://example.com/1',
      'title': 'Chương 1',
      'paragraphs': ['a', 'b'],
      'nextUrl': 'https://example.com/2',
      'prevUrl': null,
    });
    final back = ChapterContent.fromJson(c.toJson());
    expect(back.paragraphs, ['a', 'b']);
    expect(back.nextUrl, 'https://example.com/2');
    expect(back.prevUrl, null);
    expect(back.fullText, 'a\n\nb');
  });
}