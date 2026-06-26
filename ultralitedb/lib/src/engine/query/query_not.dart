part of 'query.dart';

/// Matches documents where `field != value`.
class QueryNotEquals extends Query {
  final BsonValue value;

  QueryNotEquals(String field, this.value) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    return Query.testValue(v, (e) => e != value);
  }

  @override
  String toString() => 'Query.Not("$field", $value)';
}

/// Negates any sub-query — matches when [inner] does NOT match.
class QueryNot extends Query {
  final Query inner;

  QueryNot(this.inner) : super(inner.field);

  @override
  bool filterDocument(BsonDocument doc) => !inner.filterDocument(doc);

  @override
  String toString() => 'Query.Not($inner)';
}