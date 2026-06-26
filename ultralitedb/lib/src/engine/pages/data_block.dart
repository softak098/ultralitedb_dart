part of 'data_page.dart';

/// A serialized document stored within a [DataPage].
/// Maps to C# DataBlock.
class DataBlock {
  /// Bytes on disk (excluding the inline data bytes):
  ///   position(5) + extendPageID(4) + dataLength(4)
  static const int fixedSize = 13;

  PageAddress position; // location of this block (pageID + slot)
  int extendPageID; // uint32 — overflow page, or 0xFFFFFFFF if none
  int dataLength; // total document byte length (may span ExtendPages)
  Uint8List data; // inline BSON bytes (up to page available space)

  /// Back-reference to the containing page (not serialized).
  DataPage? page;

  DataBlock({
    required this.position,
    required this.dataLength,
    required this.data,
    this.extendPageID = PageAddress.emptyPageId,
    this.page,
  });

  bool get hasExtend => extendPageID != PageAddress.emptyPageId;

  // ── Serialization ─────────────────────────────────────────────────────────

  static DataBlock _read(ByteData bd, int offset, DataPage owner) {
    var p = offset;
    final pos = PageAddress.fromByteData(bd, p);
    p += PageAddress.size;
    final extPageId = bd.getUint32(p, Endian.little);
    p += 4;
    final dataLen = bd.getInt32(p, Endian.little);
    p += 4;

    // Inline bytes: min(dataLen, available space in this page)
    final inlineLen = dataLen.clamp(0, BasePage.pageSize - p);
    final inlineData = Uint8List.sublistView(
      bd.buffer.asUint8List(),
      p,
      p + inlineLen,
    );

    return DataBlock(
      position: pos,
      extendPageID: extPageId,
      dataLength: dataLen,
      data: inlineData,
      page: owner,
    );
  }

  void _write(ByteData bd, int offset) {
    var p = offset;
    position.writeToByteData(bd, p);
    p += PageAddress.size;
    bd.setUint32(p, extendPageID, Endian.little);
    p += 4;
    bd.setInt32(p, dataLength, Endian.little);
    p += 4;
    for (var i = 0; i < data.length; i++) {
      bd.setUint8(p + i, data[i]);
    }
  }

  @override
  String toString() =>
      'DataBlock(pos=$position, len=$dataLength, extend=$extendPageID)';
}
