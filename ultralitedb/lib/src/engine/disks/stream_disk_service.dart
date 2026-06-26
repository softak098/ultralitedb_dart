import 'dart:math' as math;
import 'dart:typed_data';

import '../pages/base_page.dart';
import '../pages/header_page.dart';
import '../services/disk_service.dart';
import '../structures/page_address.dart';

/// In-memory [IDiskService] backed by a [Map]<pageID → bytes>.
/// Maps to C# StreamDiskService.
///
/// - No journal (no crash recovery needed for in-memory store).
/// - Ideal for unit tests, Shrink temp copies, and ephemeral databases.
class StreamDiskService implements IDiskService {
  /// Page store: pageID → 4096-byte buffer.
  final Map<int, Uint8List> _pages = {};

  @override
  void initialize([String? password]) {
    if (_pages.isNotEmpty) return; // already initialized

    // Page 0: HeaderPage
    final header = HeaderPage(0)
      ..lastPageId = 1
      ..freeEmptyPageId = PageAddress.emptyPageId;
    _pages[0] = header.toBuffer();

    // Page 1: Lock area (zeros — lock sentinel in C# file-based version)
    _pages[1] = Uint8List(BasePage.pageSize);
  }

  // ── Page I/O ──────────────────────────────────────────────────────────────

  @override
  Uint8List readPage(int pageID) =>
      // Return a copy so callers can't accidentally mutate the store
      Uint8List.fromList(_pages[pageID] ?? Uint8List(BasePage.pageSize));

  @override
  void writePage(int pageID, Uint8List buffer) =>
      _pages[pageID] = Uint8List.fromList(buffer);

  @override
  void setLength(int fileSize) {
    final maxPageID = fileSize ~/ BasePage.pageSize;
    _pages.removeWhere((id, _) => id >= maxPageID);
  }

  @override
  int get fileLength {
    if (_pages.isEmpty) return 0;
    return (_pages.keys.reduce(math.max) + 1) * BasePage.pageSize;
  }

  // ── Journal (no-ops) ──────────────────────────────────────────────────────

  @override
  bool get isJournalEnabled => false;

  @override
  void writeJournal(List<Uint8List> pages, int lastPageID) {}

  @override
  Iterable<Uint8List> readJournal(int lastPageID) => const [];

  @override
  void clearJournal(int lastPageID) {}

  @override
  void flush() {} // in-memory — nothing to flush

  @override
  void dispose() => _pages.clear();
}
