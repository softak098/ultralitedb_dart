import 'dart:convert';
import 'dart:typed_data';
import '../structures/page_address.dart';
import 'base_page.dart';
import 'page_type.dart';

part 'collection_index.dart';

/// Stores collection metadata and index definitions.
/// Maps to C# CollectionPage.
///
/// Content layout (after 32-byte base header):
///   [32-35]  freeDataPageID  uint32
///   [36-39]  documentCount   uint32
///   [40-423] indexes         8 × 48 bytes
class CollectionPage extends BasePage {
  static const int _pFreeDataPage = 32;
  static const int _pDocCount = 36;
  static const int _pIndexes = 40;

  int freeDataPageID;
  int documentCount;
  final List<CollectionIndex> indexes;

  CollectionPage(super.pageID)
    : freeDataPageID = PageAddress.emptyPageId,
      documentCount = 0,
      indexes = List.generate(
        CollectionIndex.maxIndexes,
        (i) => CollectionIndex(slot: i),
      ) {
    pageType = PageType.collection;
  }

  // ── Index helpers ─────────────────────────────────────────────────────────

  /// Primary key index (slot 0, field `_id`).
  CollectionIndex get pk => indexes[0];

  /// Returns the first empty index slot, or `null` if all slots are used.
  CollectionIndex? getFreeIndex() {
    for (final idx in indexes) {
      if (idx.isEmpty) return idx;
    }
    return null;
  }

  /// Returns the index for [field], or `null` if not found.
  CollectionIndex? getIndex(String field) {
    for (final idx in indexes) {
      if (idx.field == field) return idx;
    }
    return null;
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  @override
  void readContent(ByteData bd) {
    freeDataPageID = bd.getUint32(_pFreeDataPage, Endian.little);
    documentCount = bd.getUint32(_pDocCount, Endian.little);
    for (var i = 0; i < CollectionIndex.maxIndexes; i++) {
      indexes[i] = CollectionIndex._read(
        bd,
        _pIndexes + i * CollectionIndex.slotSize,
        i,
      )..page = this;
    }
  }

  @override
  void writeContent(ByteData bd) {
    bd.setUint32(_pFreeDataPage, freeDataPageID, Endian.little);
    bd.setUint32(_pDocCount, documentCount, Endian.little);
    for (var i = 0; i < CollectionIndex.maxIndexes; i++) {
      indexes[i]._write(bd, _pIndexes + i * CollectionIndex.slotSize);
    }
  }
}
