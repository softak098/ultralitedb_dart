/// Marks a class for [BsonDocument] serialization code generation.
///
/// Usage:
/// ```dart
/// part 'my_model.bson.g.dart';
///
/// @BsonSerializable()
/// class MyModel {
///   final String name;
///   MyModel({required this.name});
///
///   factory MyModel.fromBsonDocument(BsonDocument doc) =>
///       _$MyModelFromBsonDocument(doc);
/// }
/// ```
/// Then run: `dart run build_runner build`
class BsonSerializable {
  const BsonSerializable();
}

/// Customizes how a single field is serialized.
class BsonField {
  /// Override the BSON document key. Defaults to the Dart field name.
  final String? name;

  /// If `true`, this field is excluded from serialization entirely.
  final bool ignore;

  const BsonField({this.name, this.ignore = false});
}
