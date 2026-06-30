import 'dart:async';
import '../pages/collection_page.dart';
import '../pages/data_page.dart';
import '../pages/extend_page.dart';
import 'index_service.dart';
import 'page_service.dart';

/// Creates, retrieves, drops and renames collections.
/// Maps to C# CollectionService.
class CollectionService {
  final PageService _pager;
  final IndexService _indexer;

  CollectionService(this._pager, this._indexer);

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Access ────────────────────────────────────────────────────────────────

  FutureOr<CollectionPage?> get(String name) {
    final pageId = _pager.header.getCollectionPageId(name);
    if (pageId == null) return null;
    return _pager.getPage<CollectionPage>(pageId);
  }

  FutureOr<CollectionPage> getOrCreate(String name) {
    return _then(get(name), (existing) {
      if (existing != null) return existing;
      return add(name);
    });
  }

  // ── DDL ───────────────────────────────────────────────────────────────────

  FutureOr<CollectionPage> add(String name) {
    return _then(_pager.newPage<CollectionPage>((id) => CollectionPage(id)), (col) {
      // Slot 0: primary key (_id) — always unique
      return _then(_indexer.createIndex(col, '_id', true), (_) {
        _pager.header.addCollection(name, col.pageID);
        _pager.setDirty(_pager.header);
        return col;
      });
    });
  }

  FutureOr<void> drop(String name) {
    return _then(get(name), (col) {
      if (col == null) return null;

      // Drop all indexes (frees IndexPage chains)
      return _dropAllIndexes(col.indexes.where((i) => i.isNotEmpty).toList(), 0, () {
        // Free DataPage chain and any ExtendPage chains within them
        return _then(_pager.getSeqPages<DataPage>(col.freeDataPageID), (dataPages) {
          return _freeDataPages(dataPages.toList(), 0, () {
            _pager.header.removeCollection(name);
            _pager.setDirty(_pager.header);
            _pager.freePage(col);
            return null;
          });
        });
      });
    });
  }

  FutureOr<void> _dropAllIndexes(List<CollectionIndex> indexes, int index, FutureOr<void> Function() onComplete) {
    if (index >= indexes.length) {
      return onComplete();
    }

    return _then(_indexer.dropIndex(indexes[index]), (_) {
      return _dropAllIndexes(indexes, index + 1, onComplete);
    });
  }

  FutureOr<void> _freeDataPages(List<DataPage> dataPages, int index, FutureOr<void> Function() onComplete) {
    if (index >= dataPages.length) {
      return onComplete();
    }

    final dataPage = dataPages[index];
    return _then(_freeExtendPages(dataPage.dataBlocks.values.toList(), 0), (_) {
      _pager.freePage(dataPage);
      return _freeDataPages(dataPages, index + 1, onComplete);
    });
  }

  FutureOr<void> _freeExtendPages(List<DataBlock> blocks, int index) {
    if (index >= blocks.length) {
      return null;
    }

    final block = blocks[index];
    if (!block.hasExtend) {
      return _freeExtendPages(blocks, index + 1);
    }

    return _then(_pager.getSeqPages<ExtendPage>(block.extendPageID), (extPages) {
      for (final ext in extPages) {
        _pager.freePage(ext);
      }
      return _freeExtendPages(blocks, index + 1);
    });
  }

  FutureOr<void> rename(String oldName, String newName) {
    return _then(get(oldName), (col) {
      if (col == null) throw StateError('Collection "$oldName" not found');
      return _then(get(newName), (existing) {
        if (existing != null) throw StateError('Collection "$newName" already exists');
        _pager.header.removeCollection(oldName);
        _pager.header.addCollection(newName, col.pageID);
        _pager.setDirty(_pager.header);
        return null;
      });
    });
  }
}
