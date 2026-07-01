import '../pages/base_page.dart';

/// In-memory page cache — keyed by pageID.
/// Maps to C# CacheService.
class CacheService {
  static const int defaultMaxSize = 5000;

  final int maxSize;
  final Map<int, BasePage> _pages = {};

  CacheService({this.maxSize = defaultMaxSize});

  // ── Access ────────────────────────────────────────────────────────────────

  T? getPage<T extends BasePage>(int pageID) => _pages[pageID] as T?;

  bool hasPage(int pageID) => _pages.containsKey(pageID);

  void addPage(BasePage page) {
    _pages[page.pageID] = page;
    if (_pages.length > maxSize) _evict();
  }

  void setDirty(BasePage page) {
    if (page.isDirty) return;
    page.isDirty = true;
  }

  // ── Dirty tracking ────────────────────────────────────────────────────────

  List<BasePage> getDirtyPages() => _pages.values.where((p) => p.isDirty).toList();

  void clearDirty() {
    for (final p in _pages.values) {
      p.isDirty = false;
    }
  }

  void clear() => _pages.clear();

  int get count => _pages.length;

  // ── Eviction (LRU-lite: remove clean pages first) ─────────────────────────

  void _evict() {
    final remove = <int>[];
    for (final e in _pages.entries) {
      if (!e.value.isDirty) {
        remove.add(e.key);
        if (_pages.length - remove.length <= maxSize) break;
      }
    }
    for (final id in remove) {
      _pages.remove(id);
    }
  }
}
