/// Minimal, self-contained JSON Schema subset validator.
///
/// Dart has no bundled `jsonschema` equivalent, so this port always uses
/// what the Python original calls its fallback: type/enum/min-max/length/
/// required/properties/additionalProperties/items/anyOf. That is enough to
/// validate every schema this package itself produces (capability
/// parameters, `FINISH_SCHEMA`, etc.).
library;

bool _typeOk(String expected, Object? value) {
  switch (expected) {
    case 'string':
      return value is String;
    case 'integer':
      return value is int && value is! bool;
    case 'number':
      return value is num && value is! bool;
    case 'boolean':
      return value is bool;
    case 'array':
      return value is List;
    case 'object':
      return value is Map;
    case 'null':
      return value == null;
    default:
      return true;
  }
}

String _typeName(Object? value) {
  if (value == null) return 'Null';
  if (value is bool) return 'bool';
  if (value is int) return 'int';
  if (value is double) return 'double';
  if (value is String) return 'String';
  if (value is List) return 'List';
  if (value is Map) return 'Map';
  return value.runtimeType.toString();
}

/// Minimal JSON Schema subset validator (the only validator in this port —
/// mirrors Python's `_mini_validate` fallback, used unconditionally).
String? miniValidate(Map<String, Object?> schema, Object? value, [String path = '']) {
  final where = path.isEmpty ? 'arguments' : path;
  final t = schema['type'];
  if (t != null) {
    final types = t is List ? t.cast<String>() : [t as String];
    if (!types.any((x) => _typeOk(x, value))) {
      return '$where: expected type $t, got ${_typeName(value)}';
    }
  }
  if (schema.containsKey('enum')) {
    final enumValues = schema['enum'] as List;
    if (!enumValues.contains(value)) {
      return '$where: $value is not one of $enumValues';
    }
  }
  if (value is num && value is! bool) {
    if (schema.containsKey('minimum') && value < (schema['minimum'] as num)) {
      return '$where: $value is less than minimum ${schema['minimum']}';
    }
    if (schema.containsKey('maximum') && value > (schema['maximum'] as num)) {
      return '$where: $value is greater than maximum ${schema['maximum']}';
    }
  }
  if (value is String) {
    if (schema.containsKey('minLength') && value.length < (schema['minLength'] as num)) {
      return '$where: shorter than minLength ${schema['minLength']}';
    }
    if (schema.containsKey('maxLength') && value.length > (schema['maxLength'] as num)) {
      return '$where: longer than maxLength ${schema['maxLength']}';
    }
  }
  if (value is Map) {
    final valueMap = value.cast<String, Object?>();
    for (final req in (schema['required'] as List? ?? [])) {
      if (!valueMap.containsKey(req)) {
        return '$where: missing required property "$req"';
      }
    }
    final props = (schema['properties'] as Map?)?.cast<String, Object?>() ?? {};
    for (final entry in props.entries) {
      if (valueMap.containsKey(entry.key) && entry.value is Map) {
        final err = miniValidate(
          (entry.value as Map).cast<String, Object?>(),
          valueMap[entry.key],
          '$where.${entry.key}',
        );
        if (err != null) return err;
      }
    }
    if (schema['additionalProperties'] == false) {
      final extra = valueMap.keys.toSet().difference(props.keys.toSet()).toList()..sort();
      if (extra.isNotEmpty) {
        return '$where: unexpected properties $extra';
      }
    }
  }
  if (value is List && schema['items'] is Map) {
    final itemSchema = (schema['items'] as Map).cast<String, Object?>();
    for (var i = 0; i < value.length; i++) {
      final err = miniValidate(itemSchema, value[i], '$where[$i]');
      if (err != null) return err;
    }
  }
  if (schema.containsKey('anyOf')) {
    final errs = <String>[];
    var matched = false;
    for (final sub in (schema['anyOf'] as List)) {
      final err = miniValidate((sub as Map).cast<String, Object?>(), value, where);
      if (err == null) {
        matched = true;
        break;
      }
      errs.add(err);
    }
    if (!matched) {
      return '$where: no anyOf branch matched (${errs.join('; ')})';
    }
  }
  return null;
}

/// Fill missing top-level arguments that declare a schema default.
Map<String, Object?> applyDefaults(Map<String, Object?> schema, Map<String, Object?> args) {
  final out = Map<String, Object?>.from(args);
  final props = (schema['properties'] as Map?)?.cast<String, Object?>() ?? {};
  for (final entry in props.entries) {
    if (!out.containsKey(entry.key) && entry.value is Map) {
      final sub = (entry.value as Map).cast<String, Object?>();
      if (sub.containsKey('default')) {
        out[entry.key] = sub['default'];
      }
    }
  }
  return out;
}

/// Return an error message, or null when the arguments pass.
String? validateArgs(Map<String, Object?> schema, Object? args) {
  if (args is! Map) {
    return 'arguments must be a JSON object, got ${_typeName(args)}';
  }
  return miniValidate(schema, args.cast<String, Object?>());
}
