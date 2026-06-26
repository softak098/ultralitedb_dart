part of 'query.dart';

/// Matches documents where [field] is null, does not exist,
/// or is an empty string. Maps to C# QueryEmpty.
class QueryEmpty extends Query {
  QueryEmpty(String field) : super(field);

  @override
  bool filterDocument(BsonDocument doc) {
    final v = Query.getFieldValue(doc, field);
    if (v.isNull) return true;
    if (v.isString) return v.asStringOrEmpty.isEmpty;
    return false;
  }

  @override
  String toString() => 'Query.Empty("$field")';
}