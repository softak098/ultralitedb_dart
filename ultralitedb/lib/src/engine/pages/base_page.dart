import 'dart:typed_data';
import '../structures/page_address.dart';
import 'page_type.dart';

/// Abstract base for every 4096-byte database page.
/// Header layout (32 bytes, little-endian):
///   [00-03] pageID      uint32
///   [04]    pageType    byte
///   [05-08] prevPageID  uint32
///   [09-12] nextPageID  uint32
///   [13]    itemCount   byte
///   [14-17] freeBytes   int32
///   [18-31] reserved
abstract class BasePage {
  static const int pageSize = 4096;
  static const int pageHeaderSize = 32;
  static const int pageAvailableBytes = pageSize - pageHeaderSize; // 4064

  /// Byte offset of page [pageCount] in the database file.
  /// Maps to C# BasePage.GetSizeOfPages(n).
  static int getSizeOfPages(int pageCount) => pageCount * pageSize;

  // Header byte offsets
  static const int _pPageId = 0;
  static const int _pPageType = 4;
  static const int _pPrevPage = 5;
  static const int _pNextPage = 9;
  static const int _pItemCount = 13;
  static const int _pFreeBytes = 14;

  int pageID;
  PageType pageType;
  int prevPageID; // uint32
  int nextPageID; // uint32
  int itemCount; // byte
  int freeBytes; // int32
  bool isDirty;

  BasePage(this.pageID)
    : pageType = PageType.empty,
      prevPageID = PageAddress.emptyPageId,
      nextPageID = PageAddress.emptyPageId,
      itemCount = 0,
      freeBytes = pageAvailableBytes,
      isDirty = false;

  // ── Read / Write ──────────────────────────────────────────────────────────

  /// Reads header fields from a PAGE_SIZE buffer.
  void readHeader(ByteData bd) {
    pageID = bd.getUint32(_pPageId, Endian.little);
    pageType = PageType.fromByte(bd.getUint8(_pPageType));
    prevPageID = bd.getUint32(_pPrevPage, Endian.little);
    nextPageID = bd.getUint32(_pNextPage, Endian.little);
    itemCount = bd.getUint8(_pItemCount);
    freeBytes = bd.getInt32(_pFreeBytes, Endian.little);
  }

  /// Reads page content (after header) from the buffer.
  void readContent(ByteData bd);

  /// Serializes the full page into a new PAGE_SIZE [Uint8List].
  Uint8List toBuffer() {
    final buffer = Uint8List(pageSize);
    final bd = ByteData.sublistView(buffer);
    _writeHeader(bd);
    writeContent(bd);
    return buffer;
  }

  void _writeHeader(ByteData bd) {
    bd.setUint32(_pPageId, pageID, Endian.little);
    bd.setUint8(_pPageType, pageType.value);
    bd.setUint32(_pPrevPage, prevPageID, Endian.little);
    bd.setUint32(_pNextPage, nextPageID, Endian.little);
    bd.setUint8(_pItemCount, itemCount);
    bd.setInt32(_pFreeBytes, freeBytes, Endian.little);
    // [18-31] stay zeroed — Uint8List default
  }

  /// Serializes page-specific content (after the 32-byte header).
  void writeContent(ByteData bd);

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool get hasPrev => prevPageID != PageAddress.emptyPageId;
  bool get hasNext => nextPageID != PageAddress.emptyPageId;

  @override
  String toString() => '${pageType.name}(id=$pageID, free=$freeBytes)';
}
