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
library;

import 'dart:convert';

const JsonEncoder _encoder = JsonEncoder();

String dumps(Object? obj) => _encoder.convert(jsonSafe(obj));

/// Recursively replace anything `jsonEncode` cannot represent with its
/// string form. Map keys become strings, as they must be in JSON.
Object? jsonSafe(Object? obj) {
  if (obj == null || obj is num || obj is bool || obj is String) return obj;
  if (obj is Map) return obj.map((k, v) => MapEntry(k.toString(), jsonSafe(v)));
  if (obj is Iterable) return obj.map(jsonSafe).toList();
  return obj.toString();
}

/// A structural deep copy, via the same JSON representation used everywhere
/// else. Used where a copy must share no mutable state with its original —
/// a branched session's config and working state, a sub-agent's config.
T deepCopy<T>(T value) => jsonDecode(dumps(value)) as T;
