/// Event Ledger: the single append-only source of truth for a run.
///
/// Every fact worth remembering — what the user said, what was sent to the
/// model, what it decided, what policy allowed, what a command did, what got
/// approved — is appended here as an [Event]. Nothing else is authoritative:
/// conversation views, working state, and run status are all *derived* by
/// replaying (or partially replaying, via a [Snapshot]) this log. That is
/// what makes a run resumable after a process restart and makes "what
/// actually happened" answerable after the fact.
///
/// Sensitive payloads are never embedded directly in an event: callers pass
/// an artifact reference (see `artifacts.dart`) and only that opaque id is
/// written to the ledger, so a ledger file can be shipped or deleted
/// independently of the artifact store it references.
library;

import 'dart:convert';
import 'dart:io';

import 'ids.dart';

const List<String> eventTypes = [
  'user_input',
  'projection_compiled',
  'model_response',
  'decision_validated',
  'policy_decision',
  'command_started',
  'command_completed',
  'command_failed',
  'command_outcome_unknown',
  'artifact_stored',
  'approval_requested',
  'approval_resolved',
  'run_state_changed',
  'state_folded',
  'policy_changed',
  'branch_created',
  'notice',
  'observation',
  'checkpoint',
  'rewound',
];

const List<String> renderableTypes = ['user_input', 'model_response', 'observation', 'notice'];

class Event {
  Event({
    required this.id,
    required this.runId,
    required this.sequence,
    required this.type,
    required this.ts,
    Map<String, Object?>? data,
  }) : data = data ?? <String, Object?>{};

  final String id;
  final String runId;
  final int sequence;
  final String type;
  final double ts;
  final Map<String, Object?> data;

  String toLine() => jsonEncode({
        'id': id,
        'run_id': runId,
        'sequence': sequence,
        'type': type,
        'ts': ts,
        'data': data,
      });

  factory Event.fromLine(String line) {
    final d = (jsonDecode(line) as Map).cast<String, Object?>();
    return Event(
      id: d['id'] as String,
      runId: d['run_id'] as String,
      sequence: (d['sequence'] as num).toInt(),
      type: d['type'] as String,
      ts: (d['ts'] as num).toDouble(),
      data: (d['data'] as Map?)?.cast<String, Object?>() ?? {},
    );
  }
}

class Snapshot {
  Snapshot({
    required this.runId,
    required this.sequence, // last event sequence folded into this snapshot
    required this.ts,
    required this.state,
  });

  final String runId;
  final int sequence;
  final double ts;
  final Map<String, Object?> state;
}

abstract interface class EventLedger {
  Event append(String runId, String type, Map<String, Object?> data);

  Iterable<Event> iterRun(String runId, {int after = 0});

  int lastSequence(String runId);

  void saveSnapshot(Snapshot snapshot);

  Snapshot? loadSnapshot(String runId);
}

double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

void _checkType(String type) {
  if (!eventTypes.contains(type)) {
    throw ArgumentError('Unknown event type "$type"; expected one of $eventTypes');
  }
}

/// Process-local ledger: fast, exercised by every unit test, but does not
/// survive a process restart. Use [JsonlLedger] for that.
class InMemoryLedger implements EventLedger {
  final Map<String, List<Event>> _events = {};
  final Map<String, Snapshot> _snapshots = {};

  @override
  Event append(String runId, String type, Map<String, Object?> data) {
    _checkType(type);
    final list = _events.putIfAbsent(runId, () => []);
    final seq = list.length + 1;
    final event = Event(
      id: newId('event'),
      runId: runId,
      sequence: seq,
      type: type,
      ts: _nowSeconds(),
      data: data,
    );
    list.add(event);
    return event;
  }

  @override
  Iterable<Event> iterRun(String runId, {int after = 0}) sync* {
    for (final event in _events[runId] ?? const <Event>[]) {
      if (event.sequence > after) yield event;
    }
  }

  @override
  int lastSequence(String runId) {
    final events = _events[runId];
    if (events == null || events.isEmpty) return 0;
    return events.last.sequence;
  }

  @override
  void saveSnapshot(Snapshot snapshot) {
    _snapshots[snapshot.runId] = snapshot;
  }

  @override
  Snapshot? loadSnapshot(String runId) => _snapshots[runId];
}

/// File-backed ledger: one append-only `<run_id>.jsonl` per run plus a
/// `<run_id>.snapshot.json` sidecar. Surviving a process restart is the
/// entire point — `Session.resume` reads this back to restore a
/// `waitingForApproval` run.
class JsonlLedger implements EventLedger {
  JsonlLedger(String directory) : directory = Directory(directory) {
    this.directory.createSync(recursive: true);
  }

  final Directory directory;
  final Map<String, int> _lastSeq = {};

  File _path(String runId) => File('${directory.path}/$runId.jsonl');

  File _snapshotPath(String runId) =>
      File('${directory.path}/$runId.snapshot.json');

  int _seq(String runId) {
    final cached = _lastSeq[runId];
    if (cached != null) return cached;
    var n = 0;
    final path = _path(runId);
    if (path.existsSync()) {
      for (final line in path.readAsLinesSync()) {
        if (line.trim().isNotEmpty) n++;
      }
    }
    _lastSeq[runId] = n;
    return n;
  }

  @override
  Event append(String runId, String type, Map<String, Object?> data) {
    _checkType(type);
    final seq = _seq(runId) + 1;
    final event = Event(
      id: newId('event'),
      runId: runId,
      sequence: seq,
      type: type,
      ts: _nowSeconds(),
      data: data,
    );
    _path(runId).writeAsStringSync('${event.toLine()}\n',
        mode: FileMode.append, encoding: utf8);
    _lastSeq[runId] = seq;
    return event;
  }

  @override
  Iterable<Event> iterRun(String runId, {int after = 0}) sync* {
    final path = _path(runId);
    if (!path.existsSync()) return;
    for (final rawLine in path.readAsLinesSync()) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final event = Event.fromLine(line);
      if (event.sequence > after) yield event;
    }
  }

  @override
  int lastSequence(String runId) => _seq(runId);

  @override
  void saveSnapshot(Snapshot snapshot) {
    final payload = {
      'run_id': snapshot.runId,
      'sequence': snapshot.sequence,
      'ts': snapshot.ts,
      'state': snapshot.state,
    };
    final target = _snapshotPath(snapshot.runId);
    final tmp = File('${target.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(payload), encoding: utf8);
    tmp.renameSync(target.path);
  }

  @override
  Snapshot? loadSnapshot(String runId) {
    final path = _snapshotPath(runId);
    if (!path.existsSync()) return null;
    final d = (jsonDecode(path.readAsStringSync()) as Map).cast<String, Object?>();
    return Snapshot(
      runId: d['run_id'] as String,
      sequence: (d['sequence'] as num).toInt(),
      ts: (d['ts'] as num).toDouble(),
      state: (d['state'] as Map).cast<String, Object?>(),
    );
  }
}

/// Convert a renderable event into a message dict for projection.
/// Returns null for non-renderable event types.
Map<String, Object?>? eventToMessage(Event event) {
  switch (event.type) {
    case 'user_input':
      return {'role': 'user', 'content': event.data['text'] ?? ''};
    case 'model_response':
      final calls = <Map<String, Object?>>[
        for (final c in (event.data['calls'] as List? ?? []))
          {
            'name': (c as Map)['name'] ?? '',
            'arguments': c['arguments'] ?? {},
            'id': c['id'] ?? '',
          },
      ];
      return {'role': 'assistant', 'content': event.data['text'] ?? '', 'tool_calls': calls};
    case 'observation':
      return {
        'role': 'tool',
        'content': event.data['text'] ?? '',
        'tool_call_id': event.data['call_id'],
        'name': event.data['name'],
      };
    case 'notice':
      return {'role': 'system', 'content': event.data['text'] ?? ''};
    default:
      return null;
  }
}
