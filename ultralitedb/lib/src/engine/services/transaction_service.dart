import 'disk_service.dart';
import 'page_service.dart';

/// Wraps dirty-page write-back with optional journal for crash recovery.
/// Maps to C# TransactionService (simplified: no file locks needed in Dart).
class TransactionService {
  final IDiskService _disk;
  final PageService _pager;

  bool _active = false;
  bool get isActive => _active;

  TransactionService(this._disk, this._pager);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void begin() {
    if (_active) throw StateError('A transaction is already active');
    _active = true;
  }

  /// 1. Write dirty pages to journal (if enabled).
  /// 2. Persist dirty pages to the data area.
  /// 3. Remove journal (if enabled).
  /// 4. Flush OS buffers.
  Future<void> commit() async {
    if (!_active) throw StateError('No active transaction to commit');

    final dirty = _pager.cache.getDirtyPages();
    final lastPageId = _pager.header.lastPageId;

    if (dirty.isNotEmpty) {
      if (_disk.isJournalEnabled) {
        // Write new page state to journal BEFORE touching data area
        await _disk.writeJournal(dirty.map((p) => p.toBuffer()).toList(), lastPageId);
      }

      await _pager.flushDirtyPages(); // write to data area

      if (_disk.isJournalEnabled) {
        await _disk.clearJournal(lastPageId); // truncate journal area
      }

      await _disk.flush();
    }

    _active = false;
  }

  /// Discards all in-memory changes and re-reads the header from disk.
  Future<void> rollback() async {
    if (!_active) throw StateError('No active transaction to roll back');
    _pager.cache.clear();
    await _pager.initialize(); // re-reads header (no journal needed — nothing was written)
    _active = false;
  }

  /// Commit current transaction and immediately begin a new one.
  Future<void> checkpoint() async {
    if (_active) await commit();
    begin();
  }
}
