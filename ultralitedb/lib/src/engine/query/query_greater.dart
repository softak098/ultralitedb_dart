part of 'query.dart';

/// Matches documents where `field > value` (GT) or `field >= value` (GTE).
class QueryGreater extends Query {
  final BsonValue value;

  /// When `true` this is GTE (>=); when `false` it is GT (>).
  final bool isEquals;

  QueryGreater(String field, this.value, this.isEquals) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    if (v.isNull) return false;
    return Query.testValue(
      v,
      isEquals ? (e) => e >= value : (e) => e > value,
    );
  }

  @override
  String toString() =>
      isEquals ? 'Query.GTE("$field", $value)' : 'Query.GT("$field", $value)';
}