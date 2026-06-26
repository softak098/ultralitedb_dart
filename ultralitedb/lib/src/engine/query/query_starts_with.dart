part of 'query.dart';

/// Matches documents where the string [field] starts with [value].
class QueryStartsWith extends Query {
  final String value;

  QueryStartsWith(String field, this.value) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    return Query.testValue(
      v,
      (e) => e.isString && e.asStringOrEmpty.startsWith(value),
    );
  }

  @override
  String toString() => 'Query.StartsWith("$field", "$value")';
}