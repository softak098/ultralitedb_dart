part of 'collection_page.dart';

/// Metadata for a single index on a collection.
/// Stored in a fixed 48-byte slot inside [CollectionPage].
/// Maps to C# CollectionIndex.
class CollectionIndex {
  static const int maxIndexes = 8;
  static const int slotSize = 48; // bytes per slot

  //  Slot layout (48 bytes):
  //  [00]     nameLen        byte  (0 = empty slot)
  //  [01-32]  name           32 bytes (null-padded UTF-8)
  //  [33]     unique         byte
  //  [34-38]  head           PageAddress (5 bytes)
  //  [39-43]  tail           PageAddress (5 bytes)
  //  [44-47]  freeIndexPageID uint32

  int slot;
  String field;
  bool unique;
  PageAddress head;
  PageAddress tail;
  int freeIndexPageID; // uint32

  /// Back-reference — not serialized.
  CollectionPage? page;

  CollectionIndex({
    required this.slot,
    this.field = '',
    this.unique = false,
    PageAddress? head,
    PageAddress? tail,
    this.freeIndexPageID = PageAddress.emptyPageId,
    this.page,
  }) : head = head ?? PageAddress.empty,
       tail = tail ?? PageAddress.empty;

  bool get isEmpty => field.isEmpty;
  bool get isNotEmpty => field.isNotEmpty;

  /// Slot 0 is always the primary key (_id) index.
  bool get isPK => slot == 0;

  // ── Serialization ─────────────────────────────────────────────────────────

  static CollectionIndex _read(ByteData bd, int offset, int slotIndex) {
    final nameLen = bd.getUint8(offset);
    if (nameLen == 0) return CollectionIndex(slot: slotIndex); // empty

    final nameBytes = List.generate(
      nameLen,
      (i) => bd.getUint8(offset + 1 + i),
    );
    final p = offset + 33; // skip 1 (len) + 32 (name field)
    final unique = bd.getUint8(p) != 0;
    final head = PageAddress.fromByteData(bd, p + 1);
    final tail = PageAddress.fromByteData(bd, p + 1 + PageAddress.size);
    final freeId = bd.getUint32(p + 1 + PageAddress.size * 2, Endian.little);

    return CollectionIndex(
      slot: slotIndex,
      field: utf8.decode(nameBytes),
      unique: unique,
      head: head,
      tail: tail,
      freeIndexPageID: freeId,
    );
  }

  void _write(ByteData bd, int offset) {
    if (isEmpty) {
      bd.setUint8(offset, 0);
      return;
    }

    final nameBytes = utf8.encode(field);
    final len = nameBytes.length.clamp(0, 32);
    bd.setUint8(offset, len);
    for (var i = 0; i < 32; i++) {
      bd.setUint8(offset + 1 + i, i < len ? nameBytes[i] : 0);
    }
    final p = offset + 33;
    bd.setUint8(p, unique ? 1 : 0);
    head.writeToByteData(bd, p + 1);
    tail.writeToByteData(bd, p + 1 + PageAddress.size);
    bd.setUint32(p + 1 + PageAddress.size * 2, freeIndexPageID, Endian.little);
  }
}
