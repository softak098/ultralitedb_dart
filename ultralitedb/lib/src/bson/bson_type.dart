/// BSON data type identifier byte, matching the UltraLiteDB binary format.
enum BsonType {
  minValue(0),
  null_(1),
  int32(5),
  int64(6),
  double(7),
  decimal(8),
  string(9),
  document(13),
  array(14),
  binary(15),
  objectId(16),
  guid(17),
  boolean(18),
  dateTime(19),
  maxValue(255);

  final int value;
  const BsonType(this.value);

  static BsonType fromByte(int byte) {
    for (final t in BsonType.values) {
      if (t.value == byte) return t;
    }
    throw ArgumentError('Unknown BsonType byte: $byte');
  }
}
