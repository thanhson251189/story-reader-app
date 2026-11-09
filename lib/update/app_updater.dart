import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../sources/registry.dart';

class UpdateInfo {
  final String version;
  final String changelog;
  final String url;
  UpdateInfo({required this.version, required this.changelog, required this.url});
}

class AppUpdater {
  static const repoApi =
      'https://api.github.com/repos/thanhson251189/story-reader-app/releases/latest';

  Future<UpdateInfo?> check() async {
    final current = (await PackageInfo.fromPlatform()).version;
    final res =
        await http.get(Uri.parse(repoApi)).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^v'), '');
    if (tag.isEmpty || SourceRegistry.compareVersions(tag, current) <= 0) {
      return null;
    }
    final assets = (j['assets'] as List? ?? [])
        .where((a) => (a['name'] as String? ?? '').endsWith('.apk'))
        .toList();
    return UpdateInfo(
      version: tag,
      changelog: j['body'] as String? ?? '',
      url: assets.isNotEmpty
          ? assets.first['browser_download_url'] as String
          : j['html_url'] as String,
    );
  }

  static Future<bool> showIfAny(BuildContext context) async {
    final update = await AppUpdater().check();
    if (update == null || !context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Cập nhật lên v${update.version}'),
        content: SingleChildScrollView(
          child: Text(update.changelog.isEmpty
              ? 'Có bản mới hơn bản đang chạy.'
              : update.changelog),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Để sau')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              launchUrl(Uri.parse(update.url),
                  mode: LaunchMode.externalApplication);
            },
            child: const Text('Cập nhật'),
          ),
        ],
      ),
    );
    return true;
  }
}