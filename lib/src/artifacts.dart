/// Artifact store.
///
/// Large tool results, stored projections, and model responses never pass
/// through the model's context a second time: they are stored here and
/// projected as a preview card. A reference is a *structured* JSON object,
/// never a bare string — a literal `"$h1"` string is never silently
/// rewritten into a lookup whenever it appears as an argument, so a caller
/// can always pass that literal string through a tool, and a mis-detected
/// reference can never leak one tool's output into another tool's
/// arguments. Only `{"$artifact": "<id>"}` is ever resolved; every other
/// string, including one that happens to look like an id, passes through
/// untouched.
///
/// Artifacts are namespaced by run so a sub-agent (or a resumed run) can
/// never address another run's data by guessing an id.
library;

import 'dart:convert';

import 'fs.dart';

import 'ids.dart';
import 'tokens.dart';
import 'serialization.dart';

const String refKey = r'$artifact';

String serializeValue(Object? value) {
  if (value is String) return value;
  try {
    return const JsonEncoder().convert(_jsonSafe(value));
  } catch (_) {
    return value.toString();
  }
}

Object? _jsonSafe(Object? obj) {
  if (obj == null || obj is num || obj is bool || obj is String) return obj;
  if (obj is Map) {
    return obj.map((k, v) => MapEntry(k.toString(), _jsonSafe(v)));
  }
  if (obj is Iterable) {
    return obj.map(_jsonSafe).toList();
  }
  return obj.toString();
}

bool isRef(Object? value) =>
    value is Map && value.length == 1 && value[refKey] is String;

Map<String, String> ref(String artifactId) => {refKey: artifactId};

class ArtifactRecord {
  ArtifactRecord({
    required this.id,
    required this.runId,
    required this.value,
    required this.text,
    required this.typeName,
    required this.tokens,
    this.source = '',
    double? created,
  }) : created = created ?? (DateTime.now().millisecondsSinceEpoch / 1000.0);

  final String id;
  final String runId;
  final Object? value;
  final String text;
  final String typeName;
  final int tokens;
  final String source;
  final double created;

  String sizeDesc() {
    final v = value;
    if (v is String) {
      return '${v.length} chars, ${'\n'.allMatches(v).length + 1} lines';
    }
    if (v is List) return 'len=${v.length}';
    if (v is Map) return '${v.length} keys';
    return '${text.length} chars';
  }

  Map<String, Object?> toPayload() => {
        'id': id,
        'run_id': runId,
        'type_name': typeName,
        'source': source,
        'created': created,
        'text': text,
      };

  /// Only the serialized text is persisted; anything that was not a string
  /// is parsed back, so a handler resolving the reference gets the map it
  /// stored rather than its JSON.
  factory ArtifactRecord.fromPayload(Map<String, Object?> payload) {
    final text = payload['text'] as String;
    final typeName = (payload['type_name'] as String?) ?? 'str';
    Object? value = text;
    if (typeName != 'str') {
      try {
        value = jsonDecode(text);
      } on FormatException {
        // serialized with toString(): the text is all there is
      }
    }
    return ArtifactRecord(
      id: payload['id'] as String,
      runId: payload['run_id'] as String,
      value: value,
      text: text,
      typeName: typeName,
      tokens: estimateTokens(text),
      source: (payload['source'] as String?) ?? '',
      created: (payload['created'] as num?)?.toDouble(),
    );
  }
}

String _typeNameOf(Object? value) {
  if (value == null) return 'NoneType';
  if (value is String) return 'str';
  if (value is bool) return 'bool';
  if (value is int) return 'int';
  if (value is double) return 'float';
  if (value is List) return 'list';
  if (value is Map) return 'dict';
  return value.runtimeType.toString();
}

/// Namespaced by `runId`: artifacts from one run are invisible to another.
/// Optionally persists to
/// `directory/<run_id>/<artifact_id>.json` so a resumed run can recover
/// large payloads that never made it into the ledger body.
class ArtifactStore {
  ArtifactStore(this.runId, {this.directory});

  final String runId;
  /// Directory path, or null to keep every artifact in memory only.
  final String? directory;
  final Map<String, ArtifactRecord> _records = {};

  ArtifactRecord put(Object? value, {String source = ''}) {
    final aid = newId('artifact');
    final text = serializeValue(value);
    final record = ArtifactRecord(
      id: aid,
      runId: runId,
      value: value,
      text: text,
      typeName: _typeNameOf(value),
      tokens: estimateTokens(text),
      source: source,
    );
    _records[aid] = record;
    _persist(record);
    return record;
  }

  String _file(String dir, String aid) =>
      joinPath(joinPath(dir, runId), '$aid.json');

  void _persist(ArtifactRecord record) {
    final dir = directory;
    if (dir == null) return;
    requireFileSystem('Artifact persistence')
        .writeString(_file(dir, record.id), dumps(record.toPayload()));
  }

  /// The record, recovered from disk when an earlier process wrote it: a
  /// resumed run can still read a payload that was too large to keep in the
  /// ledger body.
  ArtifactRecord? _find(String aid) {
    final known = _records[aid];
    final dir = directory;
    if (known != null || dir == null) return known;
    final fs = requireFileSystem('Artifact persistence');
    final path = _file(dir, aid);
    if (!fs.exists(path)) return known;
    final payload = (jsonDecode(fs.readString(path)) as Map).cast<String, Object?>();
    return _records[aid] = ArtifactRecord.fromPayload(payload);
  }

  ArtifactRecord getRecord(String aid) {
    final record = _find(aid);
    if (record == null) throw ArgumentError('Unknown artifact "$aid"');
    return record;
  }

  Object? get(String aid) => getRecord(aid).value;

  bool exists(String aid) => _find(aid) != null;

  /// Projection form of an artifact: id + type + size + preview.
  String refText(ArtifactRecord record,
      {String preview = 'head', int previewTokens = 120}) {
    String snippet;
    if (preview == 'tail') {
      final tail = record.text.length > previewTokens * 6
          ? record.text.substring(record.text.length - previewTokens * 6)
          : record.text;
      final reversed = String.fromCharCodes(tail.runes.toList().reversed);
      final truncatedReversed = truncateToTokens(reversed, previewTokens);
      final body =
          String.fromCharCodes(truncatedReversed.runes.toList().reversed);
      snippet = '…$body';
    } else {
      snippet = truncateToTokens(record.text, previewTokens);
      if (snippet.length < record.text.length) snippet += '…';
    }
    return '[${record.id} ${record.typeName} ${record.sizeDesc()} ~${record.tokens}tk'
        '${record.source.isNotEmpty ? ' from ${record.source}' : ''}]'
        ' preview: $snippet';
  }

  // -- peek (resident meta tool) --------------------------------------

  String peek(String aid, {String? query, String? range, int maxTokens = 600}) {
    if (!exists(aid)) {
      final known = (_records.keys.toList()..sort()).join(', ');
      final shown = aid.length > 80 ? aid.substring(0, 80) : aid;
      return 'Error: unknown artifact "$shown". '
          'Known artifacts: ${known.isEmpty ? '(none)' : known}';
    }
    final record = getRecord(aid);
    String result;
    if (range != null && range.isNotEmpty) {
      result = _peekRange(record, range);
    } else if (query != null && query.isNotEmpty) {
      result = _peekQuery(record, query);
    } else {
      result = record.text;
    }
    var out = truncateToTokens(result, maxTokens);
    if (out.length < result.length) {
      out += '\n…[truncated; ${estimateTokens(result) - maxTokens}tk more'
          ' — narrow with query/range]';
    }
    return out;
  }

  static final RegExp _rangeRe = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$');
  static final RegExp _pathPartRe = RegExp(r'[^.\[\]]+|\[\d+\]');

  static String _peekRange(ArtifactRecord record, String range) {
    final m = _rangeRe.firstMatch(range);
    if (m != null) {
      final start = int.parse(m.group(1)!);
      final end = m.group(2) != null ? int.parse(m.group(2)!) : start;
      final lines = record.text.split('\n');
      final from = (start - 1).clamp(0, lines.length);
      final to = end.clamp(0, lines.length);
      final sel = from <= to ? lines.sublist(from, to) : <String>[];
      final out = <String>[];
      var idx = start < 1 ? 1 : start;
      for (final line in sel) {
        out.add('$idx: $line');
        idx++;
      }
      return out.join('\n');
    }
    Object? value = record.value;
    try {
      for (final match in _pathPartRe.allMatches(range)) {
        final part = match.group(0)!;
        if (part.startsWith('[')) {
          final idx = int.parse(part.substring(1, part.length - 1));
          value = (value as List)[idx];
        } else {
          final map = value as Map;
          // A missing key is an error, not the value null: returning "null"
          // would hand the model a fact it never asked about.
          if (!map.containsKey(part)) {
            throw ArgumentError('no key "$part"');
          }
          value = map[part];
        }
      }
      return serializeValue(value);
    } catch (exc) {
      return 'Error: cannot resolve range/path "$range": $exc';
    }
  }

  static String _peekQuery(ArtifactRecord record, String query) {
    final lines = record.text.split('\n');
    final q = query.toLowerCase();
    final hits = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].toLowerCase().contains(q)) i,
    ];
    if (hits.isEmpty) {
      return 'No lines matching "$query" in ${record.id}.';
    }
    final out = <String>[];
    final shown = <int>{};
    for (final i in hits.take(40)) {
      for (var j = (i - 1).clamp(0, lines.length - 1);
          j <= (i + 1).clamp(0, lines.length - 1);
          j++) {
        if (!shown.contains(j)) {
          shown.add(j);
          out.add('${j + 1}: ${lines[j]}');
        }
      }
    }
    return out.join('\n');
  }

  // -- reference resolution in tool arguments --------------------------

  /// Deep-replace `{"$artifact": "..."}` objects with stored values.
  ///
  /// Deliberately does NOT special-case bare strings: `"$h1"` (or any
  /// string) always passes through as literal data. Only the structured
  /// reference form is ever resolved.
  Object? resolveArgs(Object? args) {
    if (isRef(args)) {
      final aid = (args as Map)[refKey] as String;
      if (exists(aid)) return get(aid);
      return args; // unknown ref: leave as-is, let schema validation surface it
    }
    if (args is List) {
      return [for (final a in args) resolveArgs(a)];
    }
    if (args is Map) {
      return args.map((k, v) => MapEntry(k, resolveArgs(v)));
    }
    return args;
  }
}
