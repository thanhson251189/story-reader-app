import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'web_fetcher.dart';

class WebViewFallbackScreen extends StatefulWidget {
  final String url;
  final String extractJs;
  const WebViewFallbackScreen({super.key, required this.url, required this.extractJs});

  @override
  State<WebViewFallbackScreen> createState() => _WebViewFallbackScreenState();
}

class _WebViewFallbackScreenState extends State<WebViewFallbackScreen> {
  InAppWebViewController? _controller;
  bool _extracting = false;

  Future<void> _extract() async {
    final c = _controller;
    if (c == null || _extracting) return;
    setState(() => _extracting = true);
    try {
      final r = await c.evaluateJavascript(source: widget.extractJs);
      if (r is String && r.isNotEmpty && mounted) {
        Navigator.pop(context, jsonDecode(r) as Map<String, dynamic>);
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _extracting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chưa lấy được nội dung, chờ trang tải xong rồi thử lại')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vượt kiểm tra bot')),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialSettings: WebFetcher.settings,
        onWebViewCreated: (c) => _controller = c,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _extracting ? null : _extract,
        icon: const Icon(Icons.document_scanner),
        label: Text(_extracting ? 'Đang lấy...' : 'Lấy nội dung'),
      ),
    );
  }
}