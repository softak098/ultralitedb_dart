import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'anotations.dart';

/// Generates for every class annotated with [@BsonSerializable]:
///
///   extension ClassNameBsonExtension on ClassName {
///     BsonDocument toBsonDocument() => ...;
///   }
///
///   ClassName _$ClassNameFromBsonDocument(BsonDocument doc) => ClassName(...);
class BsonSerializableGenerator extends GeneratorForAnnotation<BsonSerializable> {
  static const _fieldChecker = TypeChecker.typeNamed(BsonField);
  static const _serializableChecker = TypeChecker.typeNamed(BsonSerializable);

  // ── Entry point ────────────────────────────────────────────────────────────

  @override
  String generateForAnnotatedElement(Element element, ConstantReader annotation, BuildStep buildStep) {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError('@BsonSerializable can only be applied to a class.', element: element);
    }

    final fields = _collectFields(element);
    final ctor = _findConstructor(element);

    return [_generateExtension(element, fields), _generateFromFunction(element, fields, ctor)].join('\n');
  }

  // ── Field collection ───────────────────────────────────────────────────────

  List<_FieldInfo> _collectFields(ClassElement cls) {
    final result = <_FieldInfo>[];

    for (final field in cls.fields) {
      if (field.isStatic) continue;

      final annot = _fieldChecker.firstAnnotationOfExact(field);
      if (annot != null) {
        final cr = ConstantReader(annot);
        if (cr.read('ignore').boolValue) continue;
        final name = cr.read('name').isNull ? null : cr.read('name').stringValue;
        result.add(_FieldInfo(field.name, name ?? field.name, field.type));
      } else {
        result.add(_FieldInfo(field.name, field.name, field.type));
      }
    }

    return result;
  }

  ConstructorElement _findConstructor(ClassElement cls) => cls.constructors.firstWhere(
    (c) => (c.name?.isNotEmpty ?? false) && !c.isFactory,
    orElse: () => cls.constructors.firstWhere((c) => !c.isFactory, orElse: () => cls.constructors.first),
  );

  // ── toBsonDocument (extension) ─────────────────────────────────────────────

  String _generateExtension(ClassElement cls, List<_FieldInfo> fields) {
    final buf = StringBuffer()
      ..writeln('extension ${cls.name}BsonExtension on ${cls.name} {')
      ..writeln('  /// Auto-generated — converts this instance to a [BsonDocument].')
      ..writeln('  BsonDocument toBsonDocument() => BsonDocument({');

    for (final f in fields) {
      buf.writeln("    '${f.bsonKey}': ${_encode(f.dartName!, f.type)},");
    }

    buf
      ..writeln('  });')
      ..writeln('}');

    return buf.toString();
  }

  // ── fromBsonDocument (top-level function) ──────────────────────────────────

  String _generateFromFunction(ClassElement cls, List<_FieldInfo> fields, ConstructorElement ctor) {
    final byName = {for (final f in fields) f.dartName: f};
    final buf = StringBuffer()
      ..writeln('/// Auto-generated — reconstructs [${cls.name}] from a [BsonDocument].')
      ..writeln('/// Use via: `factory ${cls.name}.fromBsonDocument(doc) => _\$${cls.name}FromBsonDocument(doc);`')
      ..writeln('${cls.name} _\$${cls.name}FromBsonDocument(BsonDocument doc) =>')
      ..writeln('    ${cls.name}(');

    for (final param in ctor.formalParameters) {
      final field = byName[param.name];
      if (field == null) continue;

      final decode = _decode("doc['${field.bsonKey}']", field.type);
      if (param.isNamed) {
        buf.writeln('      ${param.name}: $decode,');
      } else {
        buf.writeln('      $decode,');
      }
    }

    buf.writeln('    );');
    return buf.toString();
  }

  // ── Dart → BsonValue encoding ──────────────────────────────────────────────

  String _encode(String expr, DartType type) {
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;

    String wrap(String constructor, [String? overrideExpr]) {
      final a = overrideExpr ?? (nullable ? '$expr!' : expr);
      return nullable ? '$expr != null ? $constructor($a) : BsonValue.nullValue()' : '$constructor($a)';
    }

    if (type.isDartCoreBool) return wrap('BsonValue.fromBool');
    if (type.isDartCoreInt) return wrap('BsonValue.fromInt');
    if (type.isDartCoreDouble) return wrap('BsonValue.fromDouble');
    if (type.isDartCoreString) return wrap('BsonValue.fromString');
    if (_isNamed(type, 'DateTime')) return wrap('BsonValue.fromDateTime');
    if (_isNamed(type, 'ObjectId')) return wrap('BsonValue.fromObjectId');
    if (_isNamed(type, 'Uint8List')) return wrap('BsonValue.fromBytes');

    if (type is InterfaceType && type.isDartCoreList) {
      return _encodeList(expr, type, nullable);
    }

    if (type is InterfaceType && type.isDartCoreMap) {
      return _encodeMap(expr, type, nullable);
    }

    if (type is InterfaceType && _serializableChecker.hasAnnotationOf(type.element)) {
      return nullable ? '$expr != null ? $expr!.toBsonDocument() : BsonValue.nullValue()' : '$expr.toBsonDocument()';
    }

    // Fallback — BsonValue.from() handles bool/int/double/String/DateTime/
    // List/Map<String,dynamic> at runtime.
    return 'BsonValue.from($expr)';
  }

  String _encodeList(String expr, InterfaceType type, bool nullable) {
    final arg = type.typeArguments.firstOrNull;
    final inner = arg != null ? _encode('e', arg) : 'BsonValue.from(e)';
    final call = 'BsonArray.from(${nullable ? '$expr?' : expr}.map((e) => $inner))';
    return nullable ? '($call ?? BsonValue.nullValue())' : call;
  }

  String _encodeMap(String expr, InterfaceType type, bool nullable) {
    final keyType = type.typeArguments.elementAtOrNull(0);
    final valType = type.typeArguments.elementAtOrNull(1);
    if (keyType?.isDartCoreString == true && valType != null) {
      final inner = _encode('v', valType);
      final call = 'BsonDocument(${nullable ? '$expr?' : expr}.map((k, v) => MapEntry(k, $inner)))';
      return nullable ? '($call ?? BsonValue.nullValue())' : call;
    }
    return 'BsonValue.from($expr)';
  }

  // ── BsonValue → Dart decoding ──────────────────────────────────────────────

  String _decode(String expr, DartType type) {
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;

    if (type.isDartCoreBool) return nullable ? '$expr.asBoolean' : '($expr.asBoolean ?? false)';
    if (type.isDartCoreInt) return nullable ? '$expr.asInt32' : '($expr.asInt32 ?? 0)';
    if (type.isDartCoreDouble) return nullable ? '$expr.asDouble' : '($expr.asDouble ?? 0.0)';
    if (type.isDartCoreString) return nullable ? '$expr.asString' : "($expr.asString ?? '')";

    if (_isNamed(type, 'DateTime')) {
      return nullable ? '$expr.asDateTime' : '($expr.asDateTime ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))';
    }
    if (_isNamed(type, 'ObjectId')) {
      return nullable ? '$expr.asObjectId' : '$expr.asObjectId!';
    }
    if (_isNamed(type, 'Uint8List')) {
      return nullable ? '$expr.asBinary' : '$expr.asBinary!';
    }

    if (type is InterfaceType && type.isDartCoreList) {
      return _decodeList(expr, type);
    }

    if (type is InterfaceType && type.isDartCoreMap) {
      return _decodeMap(expr, type);
    }

    if (type is InterfaceType && _serializableChecker.hasAnnotationOf(type.element)) {
      return '_\$${type.element.name}FromBsonDocument($expr as BsonDocument)';
    }

    // Fallback — return BsonValue directly; field type must be BsonValue.
    return expr;
  }

  String _decodeList(String expr, InterfaceType type) {
    final arg = type.typeArguments.firstOrNull;
    final inner = arg != null ? _decode('e', arg) : 'e';
    return '($expr as BsonArray).map((e) => $inner).toList()';
  }

  String _decodeMap(String expr, InterfaceType type) {
    final valType = type.typeArguments.elementAtOrNull(1);
    if (valType != null) {
      final inner = _decode('v', valType);
      return '($expr as BsonDocument).map((k, v) => MapEntry(k, $inner))';
    }
    return '($expr as BsonDocument)';
  }

  static bool _isNamed(DartType type, String name) => type is InterfaceType && type.element.name == name;
}

// ── Internal ──────────────────────────────────────────────────────────────────

class _FieldInfo {
  final String? dartName;
  final String? bsonKey;
  final DartType type;
  _FieldInfo(this.dartName, this.bsonKey, this.type);
}
