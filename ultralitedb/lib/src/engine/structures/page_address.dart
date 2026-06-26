import 'dart:typed_data';

/// A (pageID, index) pointer into the database file.
/// Maps to C# struct PageAddress — serialized as 5 bytes.
class PageAddress {
  static const int emptyPageId = 0xFFFFFFFF; // uint.MaxValue
  static const int size = 5; // bytes on disk: uint32 + byte

  static final PageAddress empty = const PageAddress(emptyPageId, 0xFF);

  final int pageID; // uint32 (0 – 0xFFFFFFFF)
  final int index; // byte  (0 – 255)

  const PageAddress(this.pageID, this.index);

  bool get isEmpty => pageID == emptyPageId;

  // ── Serialization ─────────────────────────────────────────────────────────

  static PageAddress fromByteData(ByteData bd, int offset) =>
      PageAddress(bd.getUint32(offset, Endian.little), bd.getUint8(offset + 4));

  void writeToByteData(ByteData bd, int offset) {
    bd.setUint32(offset, pageID, Endian.little);
    bd.setUint8(offset + 4, index);
  }

  // ── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      other is PageAddress && pageID == other.pageID && index == other.index;

  @override
  int get hashCode => pageID ^ index;

  @override
  String toString() => isEmpty ? '----' : '$pageID:$index';
}
