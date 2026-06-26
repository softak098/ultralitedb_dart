part of 'query.dart';

/// Matches documents where `field < value` (LT) or `field <= value` (LTE).
class QueryLess extends Query {
  final BsonValue value;

  /// When `true` this is LTE (<=); when `false` it is LT (<).
  final bool isEquals;

  QueryLess(String field, this.value, this.isEquals) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    if (v.isNull) return false;
    return Query.testValue(
      v,
      isEquals ? (e) => e <= value : (e) => e < value,
    );
  }

  @override
  String toString() =>
      isEquals ? 'Query.LTE("$field", $value)' : 'Query.LT("$field", $value)';
}