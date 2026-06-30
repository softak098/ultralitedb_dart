import 'dart:async';
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

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void begin() {
    if (_active) throw StateError('A transaction is already active');
    _active = true;
  }

  /// 1. Write dirty pages to journal (if enabled).
  /// 2. Persist dirty pages to the data area.
  /// 3. Remove journal (if enabled).
  /// 4. Flush OS buffers.
  FutureOr<void> commit() {
    if (!_active) throw StateError('No active transaction to commit');

    final dirty = _pager.cache.getDirtyPages();
    final lastPageId = _pager.header.lastPageId;

    if (dirty.isEmpty) {
      _active = false;
      return null;
    }

    if (_disk.isJournalEnabled) {
      return _then(_disk.writeJournal(dirty.map((p) => p.toBuffer()).toList(), lastPageId), (_) {
        return _then(_pager.flushDirtyPages(), (_) {
          return _then(_disk.clearJournal(lastPageId), (_) {
            return _then(_disk.flush(), (_) {
              _active = false;
              return null;
            });
          });
        });
      });
    } else {
      return _then(_pager.flushDirtyPages(), (_) {
        return _then(_disk.flush(), (_) {
          _active = false;
          return null;
        });
      });
    }
  }

  /// Discards all in-memory changes and re-reads the header from disk.
  FutureOr<void> rollback() {
    if (!_active) throw StateError('No active transaction to roll back');
    _pager.cache.clear();
    return _then(_pager.initialize(), (_) {
      _active = false;
      return null;
    });
  }

  /// Commit current transaction and immediately begin a new one.
  FutureOr<void> checkpoint() {
    if (_active) {
      return _then(commit(), (_) {
        begin();
        return null;
      });
    }
    begin();
    return null;
  }
}
