import 'dart:math' as math;
import 'dart:typed_data';
import '../../bson/bson_value.dart';
import '../../bson/reader.dart';
import '../../bson/writer.dart';
import '../pages/base_page.dart';
import '../pages/collection_page.dart';
import '../pages/data_page.dart';
import '../pages/extend_page.dart';
import '../structures/page_address.dart';
import 'page_service.dart';

/// Stores/retrieves serialized BSON documents using [DataPage] + [ExtendPage].
/// Maps to C# DataService.
class DataService {
  final PageService _pager;

  DataService(this._pager);

  // ── Write ─────────────────────────────────────────────────────────────────

  Future<DataBlock> insert(CollectionPage col, BsonDocument doc) async {
    final bytes = BsonWriter.serializeDocument(doc);

    final dataPage = await _getOrCreateDataPage(col, bytes.length);
    final slot = _nextSlot(dataPage.dataBlocks.keys);

    // Inline as much as fits on the DataPage
    final inlineLen = math.min(bytes.length, dataPage.freeBytes - DataBlock.fixedSize);
    final inlineData = Uint8List.sublistView(bytes, 0, inlineLen);

    final block = DataBlock(
      position: PageAddress(dataPage.pageID, slot),
      dataLength: bytes.length,
      data: inlineData,
      page: dataPage,
    );

    dataPage.addBlock(block);
    _pager.setDirty(dataPage);

    // Write remaining bytes into ExtendPage chain
    if (bytes.length > inlineLen) {
      await _writeExtendChain(block, bytes, inlineLen);
    }

    col.documentCount++;
    _pager.setDirty(col);
    return block;
  }

  Future<DataBlock> update(CollectionPage col, PageAddress address, BsonDocument doc) async {
    await _deleteInternal(col, address, decrementCount: false);
    return insert(col, doc);
  }

  Future<void> delete(CollectionPage col, PageAddress address) => _deleteInternal(col, address, decrementCount: true);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<BsonDocument> read(PageAddress address) async {
    final dataPage = await _pager.getPage<DataPage>(address.pageID);
    final block = dataPage.getBlock(address.index)!;

    final all = Uint8List(block.dataLength);
    all.setRange(0, block.data.length, block.data);

    if (block.hasExtend) {
      var offset = block.data.length;
      var extId = block.extendPageID;
      while (extId != PageAddress.emptyPageId && offset < block.dataLength) {
        final ext = await _pager.getPage<ExtendPage>(extId);
        final copyLen = math.min(block.dataLength - offset, ext.content.length);
        all.setRange(offset, offset + copyLen, ext.content);
        offset += copyLen;
        extId = ext.nextPageID;
      }
    }

    return BsonReader.deserializeDocument(all);
  }

  // ── Private ───────────────────────────────────────────────────────────────

  Future<void> _deleteInternal(CollectionPage col, PageAddress address, {required bool decrementCount}) async {
    final dataPage = await _pager.getPage<DataPage>(address.pageID);
    final block = dataPage.getBlock(address.index);
    if (block == null) return;

    // Free ExtendPage chain
    if (block.hasExtend) {
      var extId = block.extendPageID;
      while (extId != PageAddress.emptyPageId) {
        final ext = await _pager.getPage<ExtendPage>(extId);
        final nextId = ext.nextPageID;
        _pager.freePage(ext);
        extId = nextId;
      }
    }

    dataPage.deleteBlock(address.index);
    _pager.setDirty(dataPage);

    if (decrementCount) {
      col.documentCount--;
      _pager.setDirty(col);
    }

    // Return page to the free-data-page list if it has space
    if (dataPage.freeBytes > DataBlock.fixedSize) {
      col.freeDataPageID = dataPage.pageID;
      _pager.setDirty(col);
    }
  }

  Future<void> _writeExtendChain(DataBlock block, Uint8List bytes, int startOffset) async {
    var offset = startOffset;
    ExtendPage? prev;

    while (offset < bytes.length) {
      final ext = await _pager.newPage<ExtendPage>((id) => ExtendPage(id), prev);
      final copyLen = math.min(bytes.length - offset, BasePage.pageAvailableBytes);
      ext.content.setRange(0, copyLen, bytes.sublist(offset));
      if (prev == null) block.extendPageID = ext.pageID;
      _pager.setDirty(ext);
      prev = ext;
      offset += copyLen;
    }
  }

  Future<DataPage> _getOrCreateDataPage(CollectionPage col, int neededBytes) async {
    final minFree = DataBlock.fixedSize + math.min(neededBytes, BasePage.pageAvailableBytes);

    if (col.freeDataPageID != PageAddress.emptyPageId) {
      final page = await _pager.getPage<DataPage>(col.freeDataPageID);
      if (page.freeBytes >= minFree) return page;
    }

    DataPage? prev = col.freeDataPageID != PageAddress.emptyPageId ? await _pager.getPage<DataPage>(col.freeDataPageID) : null;

    final newPage = await _pager.newPage<DataPage>((id) => DataPage(id), prev);
    col.freeDataPageID = newPage.pageID;
    _pager.setDirty(col);
    return newPage;
  }

  static int _nextSlot(Iterable<int> used) {
    final s = used.toSet();
    var i = 0;
    while (s.contains(i)) {
      i++;
    }
    return i;
  }
}
