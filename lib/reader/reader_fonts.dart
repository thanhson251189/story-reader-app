import 'package:flutter/material.dart';

/// Font chữ của màn đọc. Nhúng sẵn, không tải lúc chạy: đọc truyện phải xem
/// trước đúng kiểu chữ và đọc được khi không có mạng. Font hệ thống mỗi máy
/// một kiểu, có máy thiếu dấu tiếng Việt.
///
/// File font ở assets/fonts, giấy phép SIL OFL 1.1 trong OFL.txt.
class ReaderFont {
  final String id;
  final String name;

  /// Một dòng giải thích, hiện dưới dãy font khi mục này đang được chọn.
  final String hint;

  /// Tên family khai trong pubspec. null = font của máy.
  final String? family;

  const ReaderFont({
    required this.id,
    required this.name,
    required this.hint,
    this.family,
  });
}

class ReaderFonts {
  static const settingKey = 'readerFont';
  static const systemId = 'system';

  /// Mẫu có dấu để thấy font có vẽ được tiếng Việt trước khi chọn.
  static const sample = 'Chữ Việt';

  static const options = <ReaderFont>[
    ReaderFont(id: systemId, name: 'Mặc định', hint: 'Font của máy'),
    ReaderFont(
      id: 'beVietnam',
      name: 'Be Vietnam Pro',
      hint: 'Sans, dấu tiếng Việt rõ',
      family: 'BeVietnamPro',
    ),
    ReaderFont(
      id: 'lexend',
      name: 'Lexend',
      hint: 'Chữ rộng, đọc lâu đỡ mỏi',
      family: 'Lexend',
    ),
    ReaderFont(
      id: 'literata',
      name: 'Literata',
      hint: 'Serif kiểu sách',
      family: 'Literata',
    ),
    ReaderFont(
      id: 'sourceSerif',
      name: 'Source Serif 4',
      hint: 'Serif quen như web truyện',
      family: 'SourceSerif4',
    ),
  ];

  /// Id lạ hoặc rỗng (bản cũ, file sao lưu hỏng) coi như font máy — không
  /// trỏ vào family không có trong app, kẻo chữ rơi sang font dự phòng lệch.
  static ReaderFont byId(String? id) {
    for (final font in options) {
      if (font.id == id) return font;
    }
    return options.firstWhere((font) => font.id == systemId);
  }

  static String? familyOf(String? id) => byId(id).family;
}

/// Dãy font cuộn ngang trong sheet cài đặt đọc. Bấm là đổi ngay chữ chương.
class ReaderFontPicker extends StatelessWidget {
  final String fontId;
  final ValueChanged<ReaderFont> onSelected;

  const ReaderFontPicker({
    super.key,
    required this.fontId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final selected = ReaderFonts.byId(fontId);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Font chữ: ${selected.name}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 2),
            itemCount: ReaderFonts.options.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final font = ReaderFonts.options[i];
              final on = font.id == selected.id;
              return Semantics(
                button: true,
                selected: on,
                label: on
                    ? 'Font ${font.name}, đang dùng. ${font.hint}'
                    : 'Font ${font.name}. ${font.hint}',
                excludeSemantics: true,
                child: Material(
                  color: on ? scheme.primaryContainer : Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: on ? scheme.primary : scheme.outlineVariant,
                      width: on ? 2 : 1,
                    ),
                  ),
                  child: InkWell(
                    onTap: () => onSelected(font),
                    child: SizedBox(
                      width: 132,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              ReaderFonts.sample,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: font.family,
                                fontSize: 18,
                                height: 1.15,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    font.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: on
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant,
                                          fontWeight: on
                                              ? FontWeight.w600
                                              : null,
                                        ),
                                  ),
                                ),
                                if (on)
                                  Icon(
                                    Icons.check,
                                    size: 16,
                                    color: scheme.primary,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(selected.hint, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
