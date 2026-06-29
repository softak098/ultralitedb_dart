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

  Future<CollectionPage?> get(String name) async {
    final pageId = _pager.header.getCollectionPageId(name);
    return pageId == null ? null : await _pager.getPage<CollectionPage>(pageId);
  }

  Future<CollectionPage> getOrCreate(String name) async => (await get(name)) ?? (await add(name));

  // ── DDL ───────────────────────────────────────────────────────────────────

  Future<CollectionPage> add(String name) async {
    final col = await _pager.newPage<CollectionPage>((id) => CollectionPage(id));

    // Slot 0: primary key (_id) — always unique
    await _indexer.createIndex(col, '_id', true);

    _pager.header.addCollection(name, col.pageID);
    _pager.setDirty(_pager.header);
    return col;
  }

  Future<void> drop(String name) async {
    final col = await get(name);
    if (col == null) return;

    // Drop all indexes (frees IndexPage chains)
    for (final idx in col.indexes.where((i) => i.isNotEmpty)) {
      await _indexer.dropIndex(idx);
    }

    // Free DataPage chain and any ExtendPage chains within them
    for (final dataPage in await _pager.getSeqPages<DataPage>(col.freeDataPageID)) {
      for (final block in dataPage.dataBlocks.values) {
        if (block.hasExtend) {
          for (final extPage in await _pager.getSeqPages<ExtendPage>(block.extendPageID)) {
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

  Future<void> rename(String oldName, String newName) async {
    final col = await get(oldName);
    if (col == null) throw StateError('Collection "$oldName" not found');
    if ((await get(newName)) != null) {
      throw StateError('Collection "$newName" already exists');
    }
    _pager.header.removeCollection(oldName);
    _pager.header.addCollection(newName, col.pageID);
    _pager.setDirty(_pager.header);
  }
}
