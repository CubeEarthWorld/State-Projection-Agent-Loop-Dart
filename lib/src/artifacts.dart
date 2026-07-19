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
/// never address another run's data by guessing an id; a parent must
/// explicitly [ArtifactStore.move] a child artifact into its own namespace
/// to receive it.
library;

import 'dart:convert';
import 'dart:io';

import 'ids.dart';
import 'tokens.dart';

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

String truncateToTokens(String text, int maxTokens) {
  if (estimateTokens(text) <= maxTokens) return text;
  var lo = 0;
  var hi = text.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (estimateTokens(text.substring(0, mid)) <= maxTokens) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return text.substring(0, lo);
}

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

/// Namespaced by `runId`: artifacts from one run are invisible to another
/// unless explicitly moved. Optionally persists to
/// `directory/<run_id>/<artifact_id>.json` so a resumed run can recover
/// large payloads that never made it into the ledger body.
class ArtifactStore {
  ArtifactStore(this.runId, {this.directory});

  final String runId;
  final Directory? directory;
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

  void _persist(ArtifactRecord record) {
    final dir = directory;
    if (dir == null) return;
    final runDir = Directory('${dir.path}/$runId');
    runDir.createSync(recursive: true);
    final payload = {
      'id': record.id,
      'run_id': record.runId,
      'type_name': record.typeName,
      'source': record.source,
      'created': record.created,
      'text': record.text,
    };
    File('${runDir.path}/${record.id}.json')
        .writeAsStringSync(jsonEncode(payload), encoding: utf8);
  }

  Object? get(String aid) => _records[aid]!.value;

  ArtifactRecord getRecord(String aid) => _records[aid]!;

  bool exists(String aid) => _records.containsKey(aid);

  /// Explicitly import a record from another store's namespace into this
  /// one (spawn child -> parent handoff).
  ArtifactRecord move(ArtifactRecord record, {String source = ''}) =>
      put(record.value, source: source.isNotEmpty ? source : record.source);

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
    final record = _records[aid]!;
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
          value = (value as Map)[part];
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
