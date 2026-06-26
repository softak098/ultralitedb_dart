// filepath:
part of 'index_page.dart';

/// Wire format per node:
///   slot(1) | levels(1) | dataBlock(5) | key_type+data(var) | [previ|nexti] * levels
class IndexNode {
  static const int baseSize = 7; // slot + levels + dataBlock bytes

  int slot;
  int levels;
  PageAddress dataBlock;
  BsonValue key;

  /// prev[0] = level-0 backward (linked list); prev[i] = skip-list level i.
  List<PageAddress> prev;

  /// next[0] = level-0 forward (linked list); next[i] = skip-list level i.
  List<PageAddress> next;

  IndexPage? page;

  // Convenience getters / setters for level-0 linked list
  PageAddress get prevNode => prev.isNotEmpty ? prev[0] : PageAddress.empty;
  PageAddress get nextNode => next.isNotEmpty ? next[0] : PageAddress.empty;
  set prevNode(PageAddress a) {
    if (prev.isNotEmpty) prev[0] = a;
  }

  set nextNode(PageAddress a) {
    if (next.isNotEmpty) next[0] = a;
  }

  PageAddress get position => page != null ? PageAddress(page!.pageID, slot) : PageAddress.empty;

  int get totalSize => baseSize + _keySize(key) + levels * 2 * PageAddress.size;

  IndexNode({required this.slot, required this.levels, required this.key, this.page})
    : dataBlock = PageAddress.empty,
      prev = List.filled(levels, PageAddress.empty),
      next = List.filled(levels, PageAddress.empty);

  // ── Serialization ─────────────────────────────────────────────────────────

  static IndexNode _read(ByteData bd, int offset, IndexPage owner) {
    var p = offset;
    final slot = bd.getUint8(p++);
    final lvls = bd.getUint8(p++);
    final data = PageAddress.fromByteData(bd, p);
    p += PageAddress.size;
    final key = _readKey(bd, p);
    p += _keySize(key);

    final prevPtrs = List.generate(lvls, (_) {
      final a = PageAddress.fromByteData(bd, p);
      p += PageAddress.size;
      return a;
    });
    final nextPtrs = List.generate(lvls, (_) {
      final a = PageAddress.fromByteData(bd, p);
      p += PageAddress.size;
      return a;
    });

    return IndexNode(slot: slot, levels: lvls, key: key, page: owner)
      ..dataBlock = data
      ..prev = prevPtrs
      ..next = nextPtrs;
  }

  void _write(ByteData bd, int offset) {
    var p = offset;
    bd.setUint8(p++, slot);
    bd.setUint8(p++, levels);
    dataBlock.writeToByteData(bd, p);
    p += PageAddress.size;
    p += _writeKey(bd, p, key);
    for (final a in prev) {
      a.writeToByteData(bd, p);
      p += PageAddress.size;
    }
    for (final a in next) {
      a.writeToByteData(bd, p);
      p += PageAddress.size;
    }
  }

  // ── Key serialization helpers ─────────────────────────────────────────────

  static int _keySize(BsonValue v) => switch (v.type) {
    BsonType.null_ || BsonType.minValue || BsonType.maxValue => 1,
    BsonType.boolean => 2,
    BsonType.int32 => 5,
    BsonType.int64 || BsonType.double || BsonType.dateTime => 9,
    BsonType.objectId => 13,
    BsonType.string => 5 + utf8.encode(v.asStringOrEmpty).length,
    _ => 1,
  };

  static BsonValue _readKey(ByteData bd, int offset) {
    var p = offset;
    final t = BsonType.fromByte(bd.getUint8(p++));
    return switch (t) {
      BsonType.null_ => BsonValue.nullValue(),
      BsonType.minValue => BsonValue.minValue,
      BsonType.maxValue => BsonValue.maxValue,
      BsonType.boolean => BsonValue.fromBool(bd.getUint8(p) != 0),
      BsonType.int32 => BsonValue.fromInt(bd.getInt32(p, Endian.little)),
      BsonType.int64 => BsonValue.fromInt64(bd.getInt64(p, Endian.little)),
      BsonType.double => BsonValue.fromDouble(bd.getFloat64(p, Endian.little)),
      BsonType.dateTime => BsonValue.fromDateTime(
        DateTime.fromMillisecondsSinceEpoch(bd.getInt64(p, Endian.little), isUtc: true),
      ),
      BsonType.objectId => BsonValue.fromObjectId(ObjectId.fromBytes(Uint8List.sublistView(bd.buffer.asUint8List(), p, p + 12))),
      BsonType.string => () {
        final len = bd.getInt32(p, Endian.little);
        final bytes = Uint8List.sublistView(bd.buffer.asUint8List(), p + 4, p + 4 + len);
        return BsonValue.fromString(utf8.decode(bytes));
      }(),
      _ => BsonValue.nullValue(),
    };
  }

  static int _writeKey(ByteData bd, int offset, BsonValue v) {
    var p = offset;
    bd.setUint8(p++, v.type.value);
    switch (v.type) {
      case BsonType.boolean:
        bd.setUint8(p, v.asBooleanOrFalse ? 1 : 0);
      case BsonType.int32:
        bd.setInt32(p, v.asInt32OrZero, Endian.little);
      case BsonType.int64:
        bd.setInt64(p, v.asInt64OrZero, Endian.little);
      case BsonType.double:
        bd.setFloat64(p, v.asDoubleOrZero, Endian.little);
      case BsonType.dateTime:
        bd.setInt64(p, (v.asDateTime ?? BsonValue.unixEpoch).millisecondsSinceEpoch, Endian.little);
      case BsonType.objectId:
        final b = v.asObjectId!.toBytes();
        for (var i = 0; i < 12; i++) bd.setUint8(p + i, b[i]);
      case BsonType.string:
        final enc = utf8.encode(v.asStringOrEmpty);
        bd.setInt32(p, enc.length, Endian.little);
        for (var i = 0; i < enc.length; i++) bd.setUint8(p + 4 + i, enc[i]);
      default:
        break;
    }
    return _keySize(v);
  }

  @override
  String toString() => 'IndexNode(slot=$slot, key=$key, levels=$levels)';
}
