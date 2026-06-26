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

  // ── Access ────────────────────────────────────────────────────────────────

  CollectionPage? get(String name) {
    final pageId = _pager.header.getCollectionPageId(name);
    return pageId == null ? null : _pager.getPage<CollectionPage>(pageId);
  }

  CollectionPage getOrCreate(String name) => get(name) ?? add(name);

  // ── DDL ───────────────────────────────────────────────────────────────────

  CollectionPage add(String name) {
    final col = _pager.newPage<CollectionPage>((id) => CollectionPage(id));

    // Slot 0: primary key (_id) — always unique
    _indexer.createIndex(col, '_id', true);

    _pager.header.addCollection(name, col.pageID);
    _pager.setDirty(_pager.header);
    return col;
  }

  void drop(String name) {
    final col = get(name);
    if (col == null) return;

    // Drop all indexes (frees IndexPage chains)
    for (final idx in col.indexes.where((i) => i.isNotEmpty)) {
      _indexer.dropIndex(idx);
    }

    // Free DataPage chain and any ExtendPage chains within them
    for (final dataPage in _pager.getSeqPages<DataPage>(col.freeDataPageID)) {
      for (final block in dataPage.dataBlocks.values) {
        if (block.hasExtend) {
          for (final extPage in _pager.getSeqPages<ExtendPage>(
            block.extendPageID,
          )) {
            _pager.freePage(extPage);
          }
        }
      }
      _pager.freePage(dataPage);
    }

    _pager.header.removeCollection(name);
    _pager.setDirty(_pager.header);
    _pager.freePage(col);
  }

  void rename(String oldName, String newName) {
    final col = get(oldName);
    if (col == null) throw StateError('Collection "$oldName" not found');
    if (get(newName) != null) {
      throw StateError('Collection "$newName" already exists');
    }
    _pager.header.removeCollection(oldName);
    _pager.header.addCollection(newName, col.pageID);
    _pager.setDirty(_pager.header);
  }
}
