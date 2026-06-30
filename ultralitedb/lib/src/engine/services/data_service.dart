import 'dart:async';
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

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  FutureOr<DataBlock> insert(CollectionPage col, BsonDocument doc) {
    final bytes = BsonWriter.serializeDocument(doc);

    return _then(_getOrCreateDataPage(col, bytes.length), (dataPage) {
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
        return _then(_writeExtendChain(block, bytes, inlineLen), (_) {
          col.documentCount++;
          _pager.setDirty(col);
          return block;
        });
      } else {
        col.documentCount++;
        _pager.setDirty(col);
        return block;
      }
    });
  }

  FutureOr<DataBlock> update(CollectionPage col, PageAddress address, BsonDocument doc) {
    return _then(_deleteInternal(col, address, decrementCount: false), (_) {
      return insert(col, doc);
    });
  }

  FutureOr<void> delete(CollectionPage col, PageAddress address) {
    return _deleteInternal(col, address, decrementCount: true);
  }

  // ── Read ──────────────────────────────────────────────────────────────────

  FutureOr<BsonDocument> read(PageAddress address) {
    return _then(_pager.getPage<DataPage>(address.pageID), (dataPage) {
      final block = dataPage.getBlock(address.index)!;

      final all = Uint8List(block.dataLength);
      all.setRange(0, block.data.length, block.data);

      if (block.hasExtend) {
        return _then(_readExtendChain(block, all), (_) {
          return BsonReader.deserializeDocument(all);
        });
      } else {
        return BsonReader.deserializeDocument(all);
      }
    });
  }

  // ── Private ───────────────────────────────────────────────────────────────

  FutureOr<void> _readExtendChain(DataBlock block, Uint8List all) {
    return _readExtendChainHelper(block.extendPageID, block.dataLength, block.data.length, all);
  }

  FutureOr<void> _readExtendChainHelper(int extId, int dataLength, int offset, Uint8List all) {
    var curExtId = extId;
    var curOffset = offset;
    while (curExtId != PageAddress.emptyPageId && curOffset < dataLength) {
      final res = _pager.getPage<ExtendPage>(curExtId);
      if (res is Future<ExtendPage>) {
        return res.then((ext) {
          final copyLen = math.min(dataLength - curOffset, ext.content.length);
          all.setRange(curOffset, curOffset + copyLen, ext.content);
          return _readExtendChainHelper(ext.nextPageID, dataLength, curOffset + copyLen, all);
        });
      }

      final ext = res;
      final copyLen = math.min(dataLength - curOffset, ext.content.length);
      all.setRange(curOffset, curOffset + copyLen, ext.content);
      curExtId = ext.nextPageID;
      curOffset += copyLen;
    }
    return null;
  }

  FutureOr<void> _deleteInternal(CollectionPage col, PageAddress address, {required bool decrementCount}) {
    return _then(_pager.getPage<DataPage>(address.pageID), (dataPage) {
      final block = dataPage.getBlock(address.index);
      if (block == null) return null;

      // Free ExtendPage chain
      if (block.hasExtend) {
        return _then(_deleteExtendChain(block.extendPageID), (_) {
          return _finishDelete(col, address, dataPage, block, decrementCount);
        });
      } else {
        return _finishDelete(col, address, dataPage, block, decrementCount);
      }
    });
  }

  FutureOr<void> _finishDelete(CollectionPage col, PageAddress address, DataPage dataPage, DataBlock block, bool decrementCount) {
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
    return null;
  }

  FutureOr<void> _deleteExtendChain(int extId) {
    var curExtId = extId;
    while (curExtId != PageAddress.emptyPageId) {
      final res = _pager.getPage<ExtendPage>(curExtId);
      if (res is Future<ExtendPage>) {
        return res.then((ext) {
          final nextId = ext.nextPageID;
          _pager.freePage(ext);
          return _deleteExtendChain(nextId);
        });
      }

      final ext = res;
      final nextId = ext.nextPageID;
      _pager.freePage(ext);
      curExtId = nextId;
    }
    return null;
  }

  FutureOr<void> _writeExtendChain(DataBlock block, Uint8List bytes, int startOffset) {
    return _writeExtendChainLoop(block, bytes, startOffset, null);
  }

  FutureOr<void> _writeExtendChainLoop(DataBlock block, Uint8List bytes, int offset, ExtendPage? prev) {
    var curOffset = offset;
    var curPrev = prev;
    while (curOffset < bytes.length) {
      final res = _pager.newPage<ExtendPage>((id) => ExtendPage(id), curPrev);
      if (res is Future<ExtendPage>) {
        return res.then((ext) {
          final copyLen = math.min(bytes.length - curOffset, BasePage.pageAvailableBytes);
          ext.content.setAll(0, Uint8List.sublistView(bytes, curOffset, curOffset + copyLen));
          if (curPrev == null) block.extendPageID = ext.pageID;
          _pager.setDirty(ext);
          return _writeExtendChainLoop(block, bytes, curOffset + copyLen, ext);
        });
      }

      final ext = res;
      final copyLen = math.min(bytes.length - curOffset, BasePage.pageAvailableBytes);
      ext.content.setAll(0, Uint8List.sublistView(bytes, curOffset, curOffset + copyLen));
      if (curPrev == null) block.extendPageID = ext.pageID;
      _pager.setDirty(ext);
      curOffset += copyLen;
      curPrev = ext;
    }
    return null;
  }

  FutureOr<DataPage> _getOrCreateDataPage(CollectionPage col, int neededBytes) {
    final minFree = DataBlock.fixedSize + math.min(neededBytes, BasePage.pageAvailableBytes);

    if (col.freeDataPageID != PageAddress.emptyPageId) {
      return _then(_pager.getPage<DataPage>(col.freeDataPageID), (page) {
        if (page.freeBytes >= minFree) {
          return page;
        }

        return _then(_pager.newPage<DataPage>((id) => DataPage(id), page), (newPage) {
          col.freeDataPageID = newPage.pageID;
          _pager.setDirty(col);
          return newPage;
        });
      });
    }

    return _then(_pager.newPage<DataPage>((id) => DataPage(id), null), (newPage) {
      col.freeDataPageID = newPage.pageID;
      _pager.setDirty(col);
      return newPage;
    });
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
