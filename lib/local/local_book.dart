import 'dart:convert';
import 'dart:typed_data';

import 'package:epubx/epubx.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hparser;
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

class LocalChapter {
  final String title;
  final List<String> paragraphs;
  const LocalChapter({required this.title, required this.paragraphs});
}

class LocalBook {
  final String title;
  final List<LocalChapter> chapters;
  final img.Image? cover;

  const LocalBook({
    required this.title,
    required this.chapters,
    this.cover,
  });

  static Future<LocalBook> parse(String ext, Uint8List bytes, String fileName) async {
    switch (ext) {
      case 'epub':
        return epub(bytes, fileName);
      case 'mobi':
      case 'azw':
      case 'azw3':
        return mobi(bytes, fileName, ext == 'mobi' ? 'MOBI' : 'AZW3');
      case 'fb2':
        return fb2(bytes, fileName);
      case 'txt':
        return txt(bytes, fileName);
      default:
        throw FormatException('Định dạng .$ext chưa hỗ trợ (EPUB, MOBI, AZW3, FB2, TXT)');
    }
  }

  static final _heading = RegExp(
    r'^(chương|hồi|quyển|phần|chapter|第)\s*[0-9ivxlcdm零〇一二三四五六七八九十百千]+\s*(章|节|回)?\s*([:：.\-–—]|$)',
    caseSensitive: false,
  );

  static List<String> _clean(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? const [] : [t];
  }

  static String _titleKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^0-9a-zà-ỹ]+'), '');

  static List<LocalChapter> _htmlChapters(String htmlText, List<(String, String?)> toc) {
    final doc = hparser.parse(htmlText);
    for (final e in doc.querySelectorAll('script, style, head')) {
      e.remove();
    }
    final body = doc.body ?? doc.documentElement;
    if (body == null) return const [];

    final all = body.querySelectorAll('*');
    final pos = <dom.Element, int>{};
    final byId = <String, int>{};
    for (var i = 0; i < all.length; i++) {
      pos[all[i]] = i;
      final id = all[i].id;
      if (id.isNotEmpty) byId.putIfAbsent(id, () => i);
    }
    final marks = <(int, String)>[];
    for (final (t, a) in toc) {
      if (a == null || a.isEmpty) continue;
      final i = byId[a];
      if (i != null) marks.add((i, t));
    }
    marks.sort((x, y) => x.$1.compareTo(y.$1));

    final chapters = <LocalChapter>[];
    var cur = <String>[];
    var title = '';
    var m = 0;

    void flush() {
      if (cur.isEmpty) return;
      if (title.isEmpty && m < marks.length) return;
      final t = title.isEmpty ? 'Phần ${chapters.length + 1}' : title;
      if (_titleKey(cur.first) == _titleKey(t)) cur.removeAt(0);
      if (cur.isNotEmpty) chapters.add(LocalChapter(title: t, paragraphs: List<String>.from(cur)));
      cur = [];
    }

    const blockSel = 'p, div, h1, h2, h3, h4, h5, h6, li, blockquote, pre';
    for (final el in all) {
      if (!_blockTags.contains(el.localName)) continue;
      if (el.querySelector(blockSel) != null) continue;
      final at = pos[el]!;
      while (m < marks.length && marks[m].$1 <= at) {
        flush();
        title = marks[m].$2;
        m++;
      }
      cur.addAll(_clean(el.text));
    }
    while (m < marks.length) {
      flush();
      title = marks[m].$2;
      m++;
    }
    flush();

    if (chapters.isEmpty) {
      final t = _clean(body.text);
      if (t.isNotEmpty) {
        return [LocalChapter(title: title.isEmpty ? 'Phần 1' : title, paragraphs: t)];
      }
    }
    return chapters;
  }

  static List<LocalChapter> _htmlParagraphsAsOne(String htmlText, String title) {
    return _htmlChapters(htmlText, [(title, null)]);
  }

  static const _blockTags = {
    'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'pre'
  };

  static List<LocalChapter> _chaptersFromParagraphs(List<String> paras) {
    final chapters = <LocalChapter>[];
    var buf = <String>[];
    var title = '';

    void flush() {
      if (buf.isEmpty) return;
      final name = title.isEmpty ? 'Phần ${chapters.length + 1}' : title;
      chapters.add(LocalChapter(title: name, paragraphs: List<String>.from(buf)));
      buf = [];
      title = '';
    }

    for (final p in paras) {
      if (p.length <= 90 && _heading.hasMatch(p)) {
        flush();
        title = p;
        continue;
      }
      buf.add(p);
    }
    flush();

    final out = <LocalChapter>[];
    for (final c in chapters) {
      out.addAll(_splitLong(c));
    }
    return out;
  }

  static List<LocalChapter> _splitLong(LocalChapter c) {
    final total = c.paragraphs.fold<int>(0, (a, p) => a + p.length);
    if (total <= 60000) return [c];
    String name(int i) => i == 0 ? c.title : '${c.title} (${i + 1})';
    final parts = <LocalChapter>[];
    var buf = <String>[];
    var n = 0;
    for (final p in c.paragraphs) {
      buf.add(p);
      n += p.length;
      if (n >= 30000) {
        parts.add(LocalChapter(title: name(parts.length), paragraphs: buf));
        buf = [];
        n = 0;
      }
    }
    if (buf.isNotEmpty) {
      parts.add(LocalChapter(title: name(parts.length), paragraphs: buf));
    }
    return parts;
  }

  static List<String> _textParagraphs(String text) {
    final out = <String>[];
    for (final block in text.split(RegExp(r'\n\s*\n'))) {
      final lines = block.trim().isEmpty
          ? const <String>[]
          : (block.length > 3000 ? block.split('\n') : [block]);
      for (final line in lines) {
        out.addAll(_clean(line.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ')));
      }
    }
    return out;
  }

  static String _decodeText(Uint8List b) {
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      return String.fromCharCodes(
          [for (var i = 2; i + 1 < b.length; i += 2) b[i] | (b[i + 1] << 8)]);
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return String.fromCharCodes(
          [for (var i = 2; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1]]);
    }
    var s = utf8.decode(b, allowMalformed: true);
    if (s.startsWith('\uFEFF')) s = s.substring(1);
    return s;
  }

  static Future<LocalBook> epub(Uint8List bytes, String fileName) async {
    final book = await EpubReader.readBook(bytes);
    final title = (book.Title ?? '').trim().isEmpty ? fileName : book.Title!.trim();

    final hrefById = <String, String>{};
    for (final it in book.Schema?.Package?.Manifest?.Items ?? const <EpubManifestItem>[]) {
      if (it.Id != null && it.Href != null) hrefById[it.Id!] = it.Href!;
    }

    final tocByFile = <String, List<(String, String?)>>{};
    void walkToc(List<EpubChapter>? cs) {
      for (final c in cs ?? const <EpubChapter>[]) {
        final f = c.ContentFileName;
        if (f != null) {
          tocByFile.putIfAbsent(f, () => []).add(((c.Title ?? '').trim(), c.Anchor));
        }
        walkToc(c.SubChapters);
      }
    }

    walkToc(book.Chapters);

    final html = book.Content?.Html ?? const <String, EpubTextContentFile>{};
    final chapters = <LocalChapter>[];
    final seen = <String>{};
    final spine = book.Schema?.Package?.Spine?.Items ?? [];
    for (final ref in spine) {
      final href = ref.IdRef == null ? null : hrefById[ref.IdRef!];
      if (href == null || !seen.add(href)) continue;
      final file = html[href];
      if (file == null) continue;
      chapters.addAll(_htmlChapters(file.Content ?? '', tocByFile[href] ?? const []));
    }

    if (chapters.isEmpty) {
      final flat = <EpubChapter>[];
      void flatten(List<EpubChapter>? cs) {
        for (final c in cs ?? const <EpubChapter>[]) {
          if (c.SubChapters == null || c.SubChapters!.isEmpty) {
            flat.add(c);
          } else {
            flatten(c.SubChapters);
          }
        }
      }

      flatten(book.Chapters);
      for (final c in flat) {
        chapters.addAll(
            _htmlChapters(c.HtmlContent ?? '', [((c.Title ?? '').trim(), null)]));
      }
    }

    if (chapters.isEmpty) {
      throw FormatException('Không tìm thấy nội dung văn bản trong file EPUB');
    }
    return LocalBook(
      title: title,
      chapters: chapters,
      cover: book.CoverImage,
    );
  }

  static int _u16(Uint8List b, int o) =>
      o + 1 < b.length ? (b[o] << 8) | b[o + 1] : 0;

  static int _u32(Uint8List b, int o) => o + 3 < b.length
      ? (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]
      : 0;

  static Uint8List _palmDoc(Uint8List data) {
    final out = <int>[];
    var i = 0;
    while (i < data.length) {
      final c = data[i++];
      if (c == 0) {
        out.add(0);
      } else if (c <= 8) {
        for (var k = 0; k < c && i < data.length; k++) {
          out.add(data[i++]);
        }
      } else if (c <= 0x7F) {
        out.add(c);
      } else if (c <= 0xBF) {
        if (i >= data.length) break;
        final d = (c << 8) | data[i++];
        final dist = (d >> 3) & 0x7FF;
        final len = (d & 7) + 3;
        if (dist == 0 || dist > out.length) break;
        final start = out.length - dist;
        for (var k = 0; k < len; k++) {
          out.add(out[start + k]);
        }
      } else {
        out.add(0x20);
        out.add(c ^ 0x80);
      }
    }
    return Uint8List.fromList(out);
  }

  static LocalBook mobi(Uint8List b, String fileName, String format) {
    if (b.length < 78) throw FormatException('File $format bị hỏng');
    final type = String.fromCharCodes(b.sublist(60, 68));
    if (!type.startsWith('BOOK')) {
      throw FormatException('File không phải là sách $format hợp lệ');
    }
    final recCount = _u16(b, 76);
    if (recCount < 2) throw FormatException('File $format không có nội dung');

    final starts = <int>[];
    for (var i = 0; i < recCount; i++) {
      final o = 78 + i * 8;
      if (o + 4 > b.length) break;
      starts.add(_u32(b, o));
    }
    if (starts.length < 2) throw FormatException('File $format bị hỏng');

    Uint8List record(int i) =>
        b.sublist(starts[i], i + 1 < starts.length ? starts[i + 1] : b.length);

    final rec0 = record(0);
    if (rec0.length < 16) throw FormatException('File $format bị hỏng');

    final compression = _u16(rec0, 0);
    final textLength = _u32(rec0, 4);
    final textRecs = _u16(rec0, 8);
    final encryption = _u16(rec0, 12);

    if (encryption != 0) {
      throw FormatException('File có DRM, không đọc được');
    }

    var version = 0;
    var encoding = 0;
    var fullName = '';
    if (rec0.length >= 16 + 4 && String.fromCharCodes(rec0.sublist(16, 20)) == 'MOBI') {
      final headerLen = _u32(rec0, 20);
      encoding = _u32(rec0, 28);
      version = _u32(rec0, 36);
      final nameOff = _u32(rec0, 84);
      final nameLen = _u32(rec0, 88);
      if (nameOff > 0 && nameLen > 0 && nameOff + nameLen <= rec0.length) {
        fullName = _decodeText(rec0.sublist(nameOff, nameOff + nameLen)).trim();
      }
      final exth = 16 + headerLen;
      if (exth + 12 <= rec0.length &&
          String.fromCharCodes(rec0.sublist(exth, exth + 4)) == 'EXTH') {
        final count = _u32(rec0, exth + 8);
        var p = exth + 12;
        for (var k = 0; k < count && p + 8 <= rec0.length; k++) {
          final t = _u32(rec0, p);
          final len = _u32(rec0, p + 4);
          if (len < 8 || p + len > rec0.length) break;
          if (t == 503) {
            final s = _decodeText(rec0.sublist(p + 8, p + len)).trim();
            if (s.isNotEmpty) fullName = s;
          }
          p += len;
        }
      }
    }
    if (version >= 8) {
      throw FormatException('AZW3/KF8 chưa hỗ trợ. Hãy chuyển sang EPUB (Calibre) rồi đọc.');
    }
    if (compression != 1 && compression != 2) {
      throw FormatException('File nén HUFF/CDIC chưa hỗ trợ. Hãy chuyển sang EPUB.');
    }

    final out = BytesBuilder(copy: false);
    final last = textRecs < recCount ? textRecs : recCount - 1;
    for (var i = 1; i <= last; i++) {
      final raw = record(i);
      out.add(compression == 1 ? raw : _palmDoc(raw));
    }
    var all = out.takeBytes();
    if (textLength > 0 && textLength < all.length) {
      all = Uint8List.sublistView(all, 0, textLength);
    }
    final text = encoding == 65001
        ? utf8.decode(all, allowMalformed: true)
        : latin1.decode(all);

    final paras = _htmlParagraphsAsOne(text, '')
        .expand((c) => c.paragraphs)
        .toList();
    final chapters = _chaptersFromParagraphs(paras);
    if (chapters.isEmpty) throw FormatException('Không đọc được nội dung file $format');

    final pdbName = utf8
        .decode(b.sublist(0, 32).takeWhile((c) => c != 0).toList(), allowMalformed: true)
        .trim();
    final name = fullName.isNotEmpty ? fullName : (pdbName.isNotEmpty ? pdbName : fileName);
    return LocalBook(title: name, chapters: chapters);
  }

  static LocalBook fb2(Uint8List bytes, String fileName) {
    final doc = XmlDocument.parse(_decodeText(bytes));
    final root = doc.rootElement;

    String firstText(String tag) => root
        .findAllElements(tag)
        .map((e) => e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');

    final title = firstText('book-title');

    final chapters = <LocalChapter>[];

    List<String> parasOf(XmlElement section) {
      final out = <String>[];
      for (final p in section.findAllElements('p')) {
        XmlElement? a = p.parent is XmlElement ? p.parent as XmlElement : null;
        var inTitle = false;
        XmlElement? nearest;
        while (a != null) {
          if (a.name.local == 'title') {
            inTitle = true;
            break;
          }
          if (a.name.local == 'section') {
            nearest = a;
            break;
          }
          a = a.parent is XmlElement ? a.parent as XmlElement : null;
        }
        if (inTitle || nearest != section) continue;
        final t = p.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isNotEmpty) out.add(t);
      }
      return out;
    }

    String? titleOf(XmlElement section) {
      final t = section.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'title')
          .map((e) => e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim())
          .firstOrNull;
      return (t == null || t.isEmpty) ? null : t;
    }

    void walk(XmlElement section, String? inherited) {
      final sub = section.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'section')
          .toList();
      final t = titleOf(section);
      final own = parasOf(section);
      if (own.isNotEmpty) {
        chapters.add(LocalChapter(
            title: t ?? inherited ?? 'Phần ${chapters.length + 1}', paragraphs: own));
      }
      for (final s in sub) {
        walk(s, t ?? inherited);
      }
    }

    for (final body in root.findAllElements('body')) {
      final secs = body.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'section')
          .toList();
      if (secs.isEmpty) {
        final ps = body
            .findAllElements('p')
            .map((p) => p.innerText.replaceAll(RegExp(r'\s+'), ' ').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (ps.isNotEmpty) {
          chapters.add(LocalChapter(title: 'Phần ${chapters.length + 1}', paragraphs: ps));
        }
      } else {
        for (final s in secs) {
          walk(s, null);
        }
      }
    }

    if (chapters.isEmpty) throw FormatException('File FB2 không có nội dung');
    return LocalBook(title: title.isEmpty ? fileName : title, chapters: chapters);
  }

  static LocalBook txt(Uint8List bytes, String fileName) {
    final text = _decodeText(bytes);
    final chapters = _chaptersFromParagraphs(_textParagraphs(text));
    if (chapters.isEmpty) throw FormatException('File TXT trống');
    return LocalBook(title: fileName, chapters: chapters);
  }
}
