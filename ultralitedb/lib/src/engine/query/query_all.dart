part of 'query.dart';

/// Matches every document in the collection.
/// Maps to C# QueryAll / Query.All().
class QueryAll extends Query {
  final int order;

  QueryAll(String field, this.order) : super(field);

  @override
  bool filterDocument(BsonDocument doc) => true;

  @override
  String toString() => 'Query.All("$field", order: $order)';
}