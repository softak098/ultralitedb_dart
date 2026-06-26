part of 'query.dart';

/// Matches documents where `start <= field <= end`.
class QueryBetween extends Query {
  final BsonValue start;
  final BsonValue end;
  final bool startEquals; // true = GTE, false = GT
  final bool endEquals;   // true = LTE, false = LT

  QueryBetween(
    String field,
    this.start,
    this.end, [
    this.startEquals = true,
    this.endEquals   = true,
  ]) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    if (v.isNull) return false;
    return Query.testValue(v, (e) {
      final startOk = startEquals ? e >= start : e > start;
      final endOk   = endEquals   ? e <= end   : e < end;
      return startOk && endOk;
    });
  }

  @override
  String toString() => 'Query.Between("$field", $start, $end)';
}