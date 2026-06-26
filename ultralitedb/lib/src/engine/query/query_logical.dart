part of 'query.dart';

/// Matches documents where EITHER [left] OR [right] matches.
class QueryOr extends Query {
  final Query left;
  final Query right;

  QueryOr(this.left, this.right) : super('');

  @override
  bool filterDocument(BsonDocument doc) =>
      left.filterDocument(doc) || right.filterDocument(doc);

  @override
  String toString() => 'Query.Or($left, $right)';
}

/// Matches documents where BOTH [left] AND [right] match.
class QueryAnd extends Query {
  final Query left;
  final Query right;

  QueryAnd(this.left, this.right) : super('');

  @override
  bool filterDocument(BsonDocument doc) =>
      left.filterDocument(doc) && right.filterDocument(doc);

  @override
  String toString() => 'Query.And($left, $right)';
}