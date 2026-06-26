/// Controls the type of auto-generated _id when inserting a document without one.
enum BsonAutoId {
  objectId(1),
  guid(2),
  int32(3),
  int64(4);

  final int value;
  const BsonAutoId(this.value);
}
