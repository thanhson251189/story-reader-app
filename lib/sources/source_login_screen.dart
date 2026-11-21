import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../fetcher/web_fetcher.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Đăng nhập ${widget.name}'),
        actions: [
          IconButton(
            tooltip: 'Nạp lại trang',
            onPressed: () {
              setState(() => _loading = true);
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
            onLoadStop: (_, _) => setState(() => _loading = false),
          ),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
