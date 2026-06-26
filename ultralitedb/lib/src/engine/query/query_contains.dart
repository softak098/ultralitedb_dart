part of 'query.dart';

/// Matches documents where the string [field] contains [value].
class QueryContains extends Query {
  final String value;

  QueryContains(String field, this.value) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    return Query.testValue(
      v,
      (e) => e.isString && e.asStringOrEmpty.contains(value),
    );
  }

  @override
  String toString() => 'Query.Contains("$field", "$value")';
}