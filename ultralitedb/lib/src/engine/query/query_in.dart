part of 'query.dart';

/// Matches documents where `field` is equal to any value in [values].
class QueryIn extends Query {
  final List<BsonValue> values;

  QueryIn(String field, this.values) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    return Query.testValue(v, (e) => values.any((val) => val == e));
  }

  @override
  String toString() => 'Query.In("$field", [${values.join(', ')}])';
}