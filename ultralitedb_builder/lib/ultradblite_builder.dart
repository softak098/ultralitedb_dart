library;

export 'src/anotations.dart';

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/bson_generator.dart';

/// Entry point for `build_runner`.
/// Registered in `build.yaml` as `bsonSerializableBuilder`.
Builder bsonSerializableBuilder(BuilderOptions options) => PartBuilder(
  [BsonSerializableGenerator()],
  '.bson.g.dart',
  header: '''
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, unused_element
''',
  allowSyntaxErrors: true,
);
