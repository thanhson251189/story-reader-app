import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/local/local_book.dart';
import 'package:story_reader/reader/toc_screen.dart';
import 'package:story_reader/sources/registry.dart';
import 'package:story_reader/tts/tts_player.dart';

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

  test('ChapterContent fromJson defaults', () {
    final c = ChapterContent.fromJson({
      'url': 'https://example.com/1',
      'title': 'Chương 1',
      'paragraphs': ['a', 'b'],
      'nextUrl': 'https://example.com/2',
    });
    expect(c.paragraphs, ['a', 'b']);
    expect(c.nextUrl, 'https://example.com/2');
    expect(c.prevUrl, null);
    final empty = ChapterContent.fromJson({});
    expect(empty.url, '');
    expect(empty.paragraphs, isEmpty);
  });

  group('sortChapters', () {
    ChapterRef ref(String url) => ChapterRef(title: url, url: url);

    test('sorts by trailing number when all URLs have one', () {
      final input = [ref('https://x/c/10'), ref('https://x/c/2'), ref('https://x/c/1')];
      final sorted = WebFetcher.sortChapters(input);
      expect(sorted.map((c) => c.url), [
        'https://x/c/1',
        'https://x/c/2',
        'https://x/c/10',
      ]);
      expect(input.first.url, 'https://x/c/10', reason: 'không mutate đầu vào');
    });

    test('keeps document order when URLs have no number', () {
      final input = [ref('https://x/gioi-thieu'), ref('https://x/chuong-mot')];
      expect(WebFetcher.sortChapters(input).map((c) => c.url),
          input.map((c) => c.url));
    });

    test('keeps document order when only some URLs have numbers', () {
      final input = [ref('https://x/c/2'), ref('https://x/phan-ket'), ref('https://x/c/1')];
      expect(WebFetcher.sortChapters(input).map((c) => c.url),
          input.map((c) => c.url));
    });
  });

  test('compareVersions', () {
    expect(SourceRegistry.compareVersions('1.2.3', '1.2.4'), lessThan(0));
    expect(SourceRegistry.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    expect(SourceRegistry.compareVersions('1.0', '1.0.0'), 0);
    expect(SourceRegistry.compareVersions('2.0.0', '1.9.9'), greaterThan(0));
  });

  group('chunkify', () {
    test('maps chunks to paragraph index and merges short sentences', () {
      final c = ChapterContent(
          url: 'u', title: 't', paragraphs: ['Câu một. Câu hai.', 'Đoạn hai.']);
      final chunks = TtsPlayer.chunkify(c);
      expect(chunks.map((ch) => ch.paraIndex), [0, 1]);
      expect(chunks.first.text, 'Câu một. Câu hai.');
    });

    test('splits paragraph longer than 1500 chars', () {
      final c = ChapterContent(url: 'u', title: 't', paragraphs: ['x' * 4000]);
      final chunks = TtsPlayer.chunkify(c);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((ch) => ch.text.length <= 1500), true);
      expect(chunks.every((ch) => ch.paraIndex == 0), true);
      expect(chunks.map((ch) => ch.text).join().length, 4000);
    });
  });

  test('LocalBook.txt splits chapters by heading', () {
    final book = LocalBook.txt(
        utf8.encode('Chương 1: Khởi đầu\n\nNội dung một.\n\nChương 2\n\nNội dung hai.'),
        'truyen');
    expect(book.title, 'truyen');
    expect(book.chapters.map((c) => c.title), ['Chương 1: Khởi đầu', 'Chương 2']);
    expect(book.chapters.first.paragraphs, ['Nội dung một.']);
  });

  test('storyUrlFromChapter', () {
    expect(storyUrlFromChapter('book:abc123:4'), 'book:abc123');
    expect(storyUrlFromChapter('https://x.com/truyen/chuong-1'), 'https://x.com/truyen');
  });
}