import '../../bson/bson_value.dart';

part 'query_all.dart';
part 'query_equals.dart';
part 'query_greater.dart';
part 'query_less.dart';
part 'query_between.dart';
part 'query_in.dart';
part 'query_starts_with.dart';
part 'query_contains.dart';
part 'query_not.dart';
part 'query_logical.dart';
part 'query_empty.dart';

/// Abstract base for all query predicates.
/// Mirrors C# abstract Query class in UltraLiteDB/Engine/Query/.
abstract class Query {
  static const int ascending  = 1;
  static const int descending = -1;

  /// The document field name this query operates on (dot-notation supported).
  final String field;

  Query(this.field);

  // ── Static factory methods ────────────────────────────────────────────────

  /// Matches ALL documents; [order] = [ascending] or [descending].
  static Query all([String field = '_id', int order = ascending]) =>
      QueryAll(field, order);

  /// `field == value`
  static Query eq(String field, BsonValue value) =>
      QueryEquals(field, value);

  /// `field > value`
  static Query gt(String field, BsonValue value) =>
      QueryGreater(field, value, false);

  /// `field >= value`
  static Query gte(String field, BsonValue value) =>
      QueryGreater(field, value, true);

  /// `field < value`
  static Query lt(String field, BsonValue value) =>
      QueryLess(field, value, false);

  /// `field <= value`
  static Query lte(String field, BsonValue value) =>
      QueryLess(field, value, true);

  /// `start <= field <= end`
  static Query between(
    String field,
    BsonValue start,
    BsonValue end, {
    bool startEquals = true,
    bool endEquals   = true,
  }) => QueryBetween(field, start, end, startEquals, endEquals);

  /// `field IN [v1, v2, ...]`
  static Query inValues(String field, Iterable<BsonValue> values) =>
      QueryIn(field, values.toList());

  /// String field starts with [value] (case-sensitive).
  static Query startsWith(String field, String value) =>
      QueryStartsWith(field, value);

  /// String field contains [value] (case-sensitive).
  static Query contains(String field, String value) =>
      QueryContains(field, value);

  /// `field != value`
  static Query not(String field, BsonValue value) =>
      QueryNotEquals(field, value);

  /// Negates any sub-query.
  static Query notQuery(Query query) => QueryNot(query);

  /// `left OR right`
  static Query or(Query left, Query right) => QueryOr(left, right);

  /// `left AND right`
  static Query and(Query left, Query right) => QueryAnd(left, right);

  /// Field is null / does not exist in the document.
  static Query empty(String field) => QueryEmpty(field);

  // ── Abstract API ──────────────────────────────────────────────────────────

  /// Returns `true` if [doc] satisfies this query.
  /// Used for in-memory document filtering after index lookup.
  bool filterDocument(BsonDocument doc);

  // ── Shared helpers ────────────────────────────────────────────────────────

  /// Resolves a (possibly dot-notation) [field] path inside [doc].
  /// Returns [BsonValue.nullValue()] when any segment is missing.
  static BsonValue getFieldValue(BsonDocument doc, String field) {
    final parts = field.split('.');
    BsonValue current = doc[parts[0]];
    for (var i = 1; i < parts.length; i++) {
      final sub = current.asDocument;
      if (sub == null) return BsonValue.nullValue();
      current = sub[parts[i]];
    }
    return current;
  }

  /// True if the [docValue] satisfies [test] for at least one element
  /// when [docValue] is a [BsonArray], or for the value itself otherwise.
  static bool testValue(BsonValue docValue, bool Function(BsonValue v) test) {
    if (docValue.isArray) {
      return docValue.asArray!.any(test);
    }
    return test(docValue);
  }
}