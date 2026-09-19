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
import 'messages.dart';
import 'serialization.dart';

const List<String> eventTypes = [
  'user_input',
  'projection_compiled',
  'model_response',
  'decision_validated',
  'command_started',
  'command_completed',
  'command_failed',
  'command_outcome_unknown',
  'approval_requested',
  'approval_resolved',
  'run_state_changed',
  'branch_created',
  'notice',
  'observation',
  'checkpoint',
  'rewound',
  'checklists_changed',
  'question_asked',
  'question_answered',
  'state_folded',
  'model_call_failed',
  'hook_intervened',
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

  String toLine() => dumps({
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

/// What a ledger knows about a run without reading its events: enough to
/// list, pick and resume one.
class RunSummary {
  RunSummary({required this.runId, required this.sessionId, required this.state, required this.ts});

  final String runId;
  final String sessionId;
  final String state;
  final double ts; // the last snapshot's time
}

List<RunSummary> _summaries(Iterable<Snapshot> snapshots) => [
      for (final s in snapshots)
        RunSummary(
            runId: s.runId,
            sessionId: (s.state['session_id'] as String?) ?? '',
            state: (s.state['state'] as String?) ?? '',
            ts: s.ts),
    ]..sort((a, b) => b.ts.compareTo(a.ts));

abstract interface class EventLedger {
  Event append(String runId, String type, Map<String, Object?> data);

  Iterable<Event> iterRun(String runId, {int after = 0});

  int lastSequence(String runId);

  void saveSnapshot(Snapshot snapshot);

  Snapshot? loadSnapshot(String runId);

  /// Every run with a snapshot, newest first.
  List<RunSummary> listRuns();
}

double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

Event _newEvent(String runId, int sequence, String type, Map<String, Object?> data) {
  if (!eventTypes.contains(type)) {
    throw ArgumentError('Unknown event type "$type"; expected one of $eventTypes');
  }
  return Event(
      id: newId('event'), runId: runId, sequence: sequence, type: type, ts: _nowSeconds(), data: data);
}

/// Process-local ledger: fast, exercised by every unit test, but does not
/// survive a process restart. Use [JsonlLedger] for that.
class InMemoryLedger implements EventLedger {
  final Map<String, List<Event>> _events = {};
  final Map<String, Snapshot> _snapshots = {};

  @override
  Event append(String runId, String type, Map<String, Object?> data) {
    final list = _events.putIfAbsent(runId, () => []);
    final event = _newEvent(runId, list.length + 1, type, data);
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

  @override
  List<RunSummary> listRuns() => _summaries(_snapshots.values);
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
    final event = _newEvent(runId, _seq(runId) + 1, type, data);
    _path(runId).writeAsStringSync('${event.toLine()}\n',
        mode: FileMode.append, encoding: utf8);
    _lastSeq[runId] = event.sequence;
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
    tmp.writeAsStringSync(dumps(payload), encoding: utf8);
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

  @override
  List<RunSummary> listRuns() {
    const suffix = '.snapshot.json';
    return _summaries([
      for (final f in directory.listSync().whereType<File>())
        if (f.path.endsWith(suffix))
          if (loadSnapshot(f.uri.pathSegments.last.substring(0, f.uri.pathSegments.last.length - suffix.length))
              case final snapshot?)
            snapshot,
    ]);
  }
}

/// The message a renderable event projects to; null for any other type.
Message? eventToMessage(Event event) {
  final data = event.data;
  switch (event.type) {
    case 'user_input':
      return Message(role: kUser, content: data['text'] ?? '');
    case 'model_response':
      return Message(role: kAssistant, content: data['text'] ?? '', toolCalls: [
        for (final c in (data['calls'] as List? ?? []))
          ToolCall.fromDict((c as Map).cast<String, Object?>()),
      ]);
    case 'observation':
      return Message(
          role: kObservation,
          content: data['text'] ?? '',
          toolCallId: data['call_id'] as String?,
          name: data['name'] as String?);
    case 'notice':
      return Message(role: kSystem, content: data['text'] ?? '');
    default:
      return null;
  }
}

/// The run's conversation, oldest first: each renderable event with the
/// message it projects to. The one scan every reader of the history shares.
List<(Event, Message)> renderable(EventLedger ledger, String runId) => [
      for (final e in ledger.iterRun(runId))
        if (eventToMessage(e) case final m?) (e, m),
    ];

/// A ledger that also hands every appended [Event] to an observer.
///
/// Observers are read-only by contract: they see what happened, they cannot
/// veto or rewrite it (that is the policy engine's job). An observer that
/// throws is ignored so it can never take the loop down with it.
class ObservedLedger implements EventLedger {
  ObservedLedger(this.inner, this.onEvent);

  final EventLedger inner;
  final void Function(Event event) onEvent;

  @override
  Event append(String runId, String type, Map<String, Object?> data) {
    final event = inner.append(runId, type, data);
    try {
      onEvent(event);
    } catch (_) {
      // observers never break the loop
    }
    return event;
  }

  @override
  Iterable<Event> iterRun(String runId, {int after = 0}) => inner.iterRun(runId, after: after);

  @override
  int lastSequence(String runId) => inner.lastSequence(runId);

  @override
  void saveSnapshot(Snapshot snapshot) => inner.saveSnapshot(snapshot);

  @override
  Snapshot? loadSnapshot(String runId) => inner.loadSnapshot(runId);

  @override
  List<RunSummary> listRuns() => inner.listRuns();
}
