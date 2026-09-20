/// The one way this package turns a value into JSON.
///
/// Every JSON string the model sees or the ledger stores goes through here:
/// tool schemas, capability specs, artifact bodies, the working-state `extra`
/// line, ledger rows. Having a single definition is what keeps the Dart and
/// Python ports byte-identical — the two drifted apart on separator spacing
/// alone, which silently changed every token estimate.
///
/// Unencodable values fall back to their `toString()` rather than throwing:
/// `extra` is documented as a free-form escape hatch, and a ledger append
/// must not fail because something in it was not JSON.
///
/// Non-finite doubles become `null`: `NaN`/`Infinity` have no JSON form,
/// `JsonEncoder` throws on them, and the Python port would otherwise write
/// the bare `NaN` token that `jsonDecode` here rejects outright.
library;

import 'dart:convert';

String dumps(Object? obj) {
  final buffer = StringBuffer();
  _write(buffer, jsonSafe(obj));
  return buffer.toString();
}

/// Writes the already-`jsonSafe` tree. Only exists so doubles can be
/// rendered the way Python's `repr` renders them — `JsonEncoder` offers no
/// hook for that, and `1e-7` vs `1e-07` is a real divergence in every tool
/// schema, artifact body and ledger row the two ports exchange. Strings are
/// delegated to `jsonEncode`, so escaping stays exactly what it always was.
void _write(StringBuffer out, Object? value) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is double) {
    out.write(formatDouble(value));
  } else if (value is num) {
    out.write(value.toString());
  } else if (value is String) {
    out.write(jsonEncode(value));
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _write(out, value[i]);
    }
    out.write(']');
  } else {
    var first = true;
    out.write('{');
    (value as Map).forEach((k, v) {
      if (!first) out.write(',');
      first = false;
      out.write(jsonEncode(k as String));
      out.write(':');
      _write(out, v);
    });
    out.write('}');
  }
}

/// A double as Python's `repr` writes it: shortest round-trip digits, and
/// scientific notation exactly when the decimal point sits at or before
/// -4, or past 16 — CPython's own cutoff. Dart's `toString` switches at
/// different places (`1e20` becomes `100000000000000000000.0`) and pads no
/// exponent, so the two ports emitted different bytes for the same number.
String formatDouble(double value) {
  if (value == 0.0) return value.isNegative ? '-0.0' : '0.0';
  final negative = value.isNegative;
  final magnitude = negative ? -value : value;
  final sign = negative ? '-' : '';

  // `toStringAsExponential()` with no argument is the shortest form that
  // still round-trips — the same guarantee Python's repr makes.
  final text = magnitude.toStringAsExponential();
  final marker = text.indexOf('e');
  final digits = text.substring(0, marker).replaceFirst('.', '');
  final pointAt = int.parse(text.substring(marker + 1)) + 1;

  if (pointAt <= -4 || pointAt > 16) {
    final mantissa =
        digits.length == 1 ? digits : '${digits[0]}.${digits.substring(1)}';
    final exponent = pointAt - 1;
    final magnitudeText = exponent.abs().toString().padLeft(2, '0');
    return '$sign${mantissa}e${exponent < 0 ? '-' : '+'}$magnitudeText';
  }
  if (pointAt <= 0) return '${sign}0.${'0' * -pointAt}$digits';
  if (pointAt >= digits.length) {
    return '$sign$digits${'0' * (pointAt - digits.length)}.0';
  }
  return '$sign${digits.substring(0, pointAt)}.${digits.substring(pointAt)}';
}

/// Recursively replace anything `jsonEncode` cannot represent with its
/// string form. Map keys become strings, as they must be in JSON.
Object? jsonSafe(Object? obj) {
  if (obj is double && !obj.isFinite) return null; // see the `null` note above
  if (obj == null || obj is num || obj is bool || obj is String) return obj;
  if (obj is Map) return obj.map((k, v) => MapEntry(k.toString(), jsonSafe(v)));
  if (obj is Iterable) return obj.map(jsonSafe).toList();
  return obj.toString();
}

/// A structural deep copy, via the same JSON representation used everywhere
/// else. Used where a copy must share no mutable state with its original —
/// a branched session's config and working state, a sub-agent's config.
T deepCopy<T>(T value) => jsonDecode(dumps(value)) as T;
