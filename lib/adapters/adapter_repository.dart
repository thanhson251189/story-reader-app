import '../core/models.dart';

class AdapterRepository {
  final Map<String, SourceAdapter> _byDomain = {};

  AdapterRepository(List<SourceAdapter> adapters) {
    mergeRemote(adapters);
  }

  void mergeRemote(List<SourceAdapter> remote) {
    for (final a in remote) {
      final existing = _byDomain[a.domain];
      if (existing == null || a.version >= existing.version) {
        _byDomain[a.domain] = a;
      }
    }
  }

  void remove(String domain) => _byDomain.remove(domain);

  SourceAdapter? forUrl(String url) {
    for (final a in _byDomain.values) {
      if (a.matches(url)) return a;
    }
    return null;
  }

  List<SourceAdapter> get all => _byDomain.values.toList();
}
