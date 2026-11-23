import 'dart:async';
import 'dart:io';

import 'models.dart';

/// Chuyển lỗi kỹ thuật thành câu tiếng Việt người thường, kèm gợi ý việc
/// cần làm. Mọi chỗ báo lỗi cho người dùng đều đi qua đây để không phun
/// thuật ngữ ("adapter", "HTTP", tên exception...) ra màn hình.
String friendlyError(Object e) {
  if (e is IncompleteTocException) {
    return e.toString();
  }
  if (e is ChallengeException) {
    return 'Trang web đang chặn bot. Bấm "Mở WebView", chờ trang tải xong '
        'rồi bấm "Lấy nội dung".';
  }
  if (e is TimeoutException) {
    return 'Mạng chậm hoặc mất kết nối. Kiểm tra wifi/4G rồi bấm "Thử lại".';
  }
  if (e is SocketException) {
    return 'Mất kết nối mạng. Kiểm tra wifi/4G rồi bấm "Thử lại".';
  }
  var raw = e.toString();
  for (final prefix in const ['Exception: ', 'FormatException: ']) {
    if (raw.startsWith(prefix)) raw = raw.substring(prefix.length);
  }
  final http = RegExp(r'^HTTP (\d{3})$').firstMatch(raw);
  if (http != null) {
    final code = http.group(1)!;
    return switch (code) {
      '403' =>
        'Trang web từ chối truy cập (thường là chặn bot). Bấm "Thử lại", '
            'không được thì bấm "Mở WebView".',
      '404' => 'Không tìm thấy trang. Link có thể sai hoặc chương đã bị xoá.',
      '429' =>
        'Trang web đang chặn vì tải quá nhiều. Chờ vài phút rồi bấm "Thử lại".',
      _ =>
        code.startsWith('5')
            ? 'Trang web đang gặp sự cố. Chờ lát rồi bấm "Thử lại".'
            : 'Trang web trả lỗi $code. Chờ lát rồi bấm "Thử lại".',
    };
  }
  if (raw.startsWith('Lỗi mạng:')) {
    return 'Không mở được trang web. Kiểm tra wifi/4G rồi bấm "Thử lại".';
  }
  if (raw.contains('Chưa có adapter')) {
    return 'App chưa biết cách đọc trang này. Mở màn "Nguồn truyện" để thêm '
        'hoặc cập nhật nguồn.';
  }
  return raw;
}
