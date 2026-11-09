import 'dart:convert';
import 'package:flutter/services.dart';
import '../core/models.dart';

class AdapterRepository {
  final Map<String, SourceAdapter> _byDomain = {};

  AdapterRepository(List<SourceAdapter> adapters) {
    for (final a in adapters) {
      _byDomain[a.domain] = a;
    }
  }

  static Future<AdapterRepository> load() async {
    // Bản phát hành để trống; chỉ bản cá nhân (PERSONAL) cài sẵn adapter.
    if (!const bool.fromEnvironment('PERSONAL')) return AdapterRepository([]);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest
        .listAssets()
        .where((k) => k.startsWith('assets/adapters/') && k.endsWith('.json'));
    final adapters = <SourceAdapter>[];
    for (final k in keys) {
      try {
        adapters.add(SourceAdapter.fromJson(
            jsonDecode(await rootBundle.loadString(k)) as Map<String, dynamic>));
      } catch (_) {}
    }
    return AdapterRepository(adapters);
  }

  void mergeRemote(List<SourceAdapter> remote) {
    for (final a in remote) {
      final existing = _byDomain[a.domain];
      if (existing == null || a.version >= existing.version) {
        _byDomain[a.domain] = a;
      }
    }
  }

  SourceAdapter? forUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    for (final a in _byDomain.values) {
      if (a.matches(url) || host == a.domain) return a;
    }
    return null;
  }

  List<SourceAdapter> get all => _byDomain.values.toList();
}