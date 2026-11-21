import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../core/models.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';

/// Đọc bản đồ tên nguồn người dùng đã đổi trong màn Nguồn. Dữ liệu hỏng thì
/// trả về rỗng thay vì sập — tên hiển thị về tên miền như thường.
Future<Map<String, String>> loadAdapterNames(AppDb db) async {
  try {
    return Map<String, String>.from(
      jsonDecode(await db.getSetting('adapterNames') ?? '{}') as Map,
    );
  } catch (_) {
    return const {};
  }
}

/// Mở màn đăng nhập cho [adapter] với tên hiển thị đã chọn. Dùng chung cho
/// màn Nguồn, màn đọc (khi lỗi) và màn Tìm kiếm — một chỗ duy nhất để tên
/// không lệch nhau giữa các màn.
Future<void> openSourceLogin(
  BuildContext context,
  SourceAdapter adapter,
  String name,
) async {
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SourceLoginScreen(name: name, url: adapter.loginUrl!),
    ),
  );
}

/// Mở trang đăng nhập của nguồn trong WebView hiển thị để người dùng tự đăng
/// nhập. Cookie lưu vào WebView dùng chung với bộ tải nền nên chỉ cần đăng nhập
/// một lần: các lần tìm kiếm, nạp mục lục, chương sau đó tự mang cookie theo.
class SourceLoginScreen extends StatefulWidget {
  final String name;
  final String url;
  const SourceLoginScreen({super.key, required this.name, required this.url});

  @override
  State<SourceLoginScreen> createState() => _SourceLoginScreenState();
}

class _SourceLoginScreenState extends State<SourceLoginScreen> {
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _loadError;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Đăng nhập ${widget.name}'),
        actions: [
          IconButton(
            tooltip: 'Nạp lại trang',
            onPressed: () {
              setState(() {
                _loading = true;
                _loadError = null;
              });
              _controller?.reload();
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Đã đăng nhập xong',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            initialSettings: WebFetcher.settings,
            onWebViewCreated: (c) => _controller = c,
            onLoadStop: (_, _) => setState(() {
              _loading = false;
              _loadError = null;
            }),
            onReceivedError: (controller, request, error) {
              // Lỗi tài nguyên phụ (ảnh, script...) không coi là hỏng trang.
              if (request.isForMainFrame != true) return;
              setState(() {
                _loading = false;
                _loadError = error.description.toString();
              });
            },
          ),
          if (_loading && _loadError == null)
            const Center(child: CircularProgressIndicator()),
          if (_loadError != null) _errorView(),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48),
            const SizedBox(height: 12),
            Text(
              'Không tải được trang đăng nhập. Kiểm tra wifi/4G rồi bấm '
              '"Thử lại".',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => setState(() {
                _loadError = null;
                _loading = true;
                _controller?.reload();
              }),
              child: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}
