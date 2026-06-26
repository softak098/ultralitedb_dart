part of 'query.dart';

/// Matches documents where `field == value`.
class QueryEquals extends Query {
  final BsonValue value;

  QueryEquals(super.field, this.value);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    return Query.testValue(v, (e) => e == value);
  }

  @override
  String toString() => 'Query.EQ("$field", $value)';
}
