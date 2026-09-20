/// Minimal, self-contained JSON Schema subset validator.
///
/// Dart has no bundled `jsonschema` equivalent, so this port always uses
/// what the Python original calls its fallback: type/enum/min-max/length/
/// required/properties/additionalProperties/items/anyOf. That is enough to
/// validate every schema this package itself produces (capability
/// parameters, `FINISH_SCHEMA`, etc.).
library;

import 'serialization.dart';

/// One name -> predicate table serving both directions: "does this value
/// have this JSON type" and "what is this value's JSON type name". Order
/// matters for the second: the first match wins, so `true` names itself
/// "boolean" and `1` "integer".
final Map<String, bool Function(Object?)> _jsonTypes = {
  'null': (v) => v == null,
  'boolean': (v) => v is bool,
  'integer': (v) => v is int,
  'number': (v) => v is num,
  'string': (v) => v is String,
  'array': (v) => v is List,
  'object': (v) => v is Map,
};

/// An unknown (or non-string) type keyword passes: a malformed capability
/// spec degrades to "unvalidated", exactly as it does in Python, rather
/// than taking the run down.
bool _typeOk(Object? expected, Object? value) {
  final ok = _jsonTypes[expected];
  return ok == null || ok(value);
}

/// Name a value's type in the JSON Schema vocabulary.
///
/// The message this feeds is a self-repair prompt sent to the model, so it
/// names types the way the schema beside it does — and identically in the
/// Python package, which would otherwise say "str" where this said "String".
String jsonTypeName(Object? value) {
  for (final entry in _jsonTypes.entries) {
    if (entry.value(value)) return entry.key;
  }
  return value.runtimeType.toString();
}

/// Python's `in` compares with `==`, which is structural for lists and
/// dicts — and, a documented wart of the reference port, treats `True` as
/// equal to `1` and `False` as `0`. Dart's `==` is identity for `List` and
/// `Map`, so an object or array `enum` member would never match.
bool _jsonEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _jsonEquals(a[k], b[k]));
  }
  return (a is bool ? (a ? 1 : 0) : a) == (b is bool ? (b ? 1 : 0) : b);
}

/// Minimal JSON Schema subset validator (the only validator in this port —
/// mirrors Python's `_mini_validate` fallback, used unconditionally).
///
/// Every keyword is read defensively rather than cast: a capability spec is
/// data, sometimes hand-written or model-written, and a malformed one must
/// degrade to "this keyword did not apply" — as it does in Python — instead
/// of throwing a `TypeError` out of the middle of a run.
String? validateValue(Map<String, Object?> schema, Object? value, [String path = '']) {
  final where = path.isEmpty ? 'arguments' : path;
  final t = schema['type'];
  if (t != null) {
    final types = t is List ? t : [t];
    if (!types.any((x) => _typeOk(x, value))) {
      return '$where: expected type ${dumps(t)}, got ${jsonTypeName(value)}';
    }
  }
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.any((e) => _jsonEquals(e, value))) {
    return '$where: ${dumps(value)} is not one of ${dumps(enumValues)}';
  }
  if (value is num) {
    final min = schema['minimum'], max = schema['maximum'];
    if (min is num && value < min) {
      return '$where: $value is less than minimum $min';
    }
    if (max is num && value > max) {
      return '$where: $value is greater than maximum $max';
    }
  }
  if (value is String) {
    // Characters, not UTF-16 code units: the checklist store enforces its
    // own limits in characters, and a schema that disagreed would reject
    // text the store would have accepted.
    final length = value.runes.length;
    final min = schema['minLength'], max = schema['maxLength'];
    if (min is num && length < min) {
      return '$where: shorter than minLength $min';
    }
    if (max is num && length > max) {
      return '$where: longer than maxLength $max';
    }
  }
  if (value is Map) {
    final valueMap = value.cast<String, Object?>();
    final required = schema['required'];
    // A `String` here iterates its characters, as Python's `for req in ...`
    // does, so the two ports report the same missing property.
    for (final req in required is List
        ? required
        : (required is String ? required.split('') : const [])) {
      if (!valueMap.containsKey(req)) {
        return '$where: missing required property ${dumps(req)}';
      }
    }
    final rawProps = schema['properties'];
    final props = rawProps is Map ? rawProps.cast<String, Object?>() : const <String, Object?>{};
    for (final entry in props.entries) {
      if (valueMap.containsKey(entry.key) && entry.value is Map) {
        final err = validateValue(
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
        return '$where: unexpected properties ${dumps(extra)}';
      }
    }
  }
  if (value is List && schema['items'] is Map) {
    final itemSchema = (schema['items'] as Map).cast<String, Object?>();
    for (var i = 0; i < value.length; i++) {
      final err = validateValue(itemSchema, value[i], '$where[$i]');
      if (err != null) return err;
    }
  }
  final anyOf = schema['anyOf'];
  if (anyOf is List) {
    // The last check in the function, so a match returns straight away -
    // the same shape as the reference port's for/else.
    final errs = <String>[];
    for (final sub in anyOf) {
      if (sub is! Map) continue;
      final err = validateValue(sub.cast<String, Object?>(), value, where);
      if (err == null) return null;
      errs.add(err);
    }
    return '$where: no anyOf branch matched (${errs.join('; ')})';
  }
  return null;
}

/// Fill missing top-level arguments that declare a schema default.
Map<String, Object?> applyDefaults(Map<String, Object?> schema, Map<String, Object?> args) {
  final out = Map<String, Object?>.from(args);
  final rawProps = schema['properties'];
  final props = rawProps is Map ? rawProps.cast<String, Object?>() : const <String, Object?>{};
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
    return 'arguments must be a JSON object, got ${jsonTypeName(args)}';
  }
  return validateValue(schema, args.cast<String, Object?>());
}
