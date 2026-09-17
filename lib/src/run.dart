/// Run state machine: the unit of resumable execution.
///
/// A [Run] is one job/conversation execution. Its state is not implicit in
/// "is the process still alive" — it is an explicit, ledger-recorded value
/// that a new process can read back after a restart. Waiting is a
/// first-class state (`WAITING_FOR_APPROVAL`, `WAITING_FOR_USER`) with its
/// own persisted record ([ApprovalRequest], [PendingQuestion]), not just a
/// hook that blocks a batch and forgets why.
///
/// A [Command] is one planned invocation of a capability. Its `id` is
/// stable across retries of the *same* logical attempt (never regenerated
/// on retry) so an external API can use it as an idempotency key, and its
/// `outcome` distinguishes three states that a timeout collapses together
/// in naive implementations: the call never started (`failed` before
/// execution), it demonstrably failed, or its result is unknown because the
/// timeout fired mid-flight (`unknown` — never safe to blindly retry).
library;

import 'capability.dart';
import 'events.dart';
import 'ids.dart';
import 'messages.dart';

const List<String> runStates = [
  'RUNNING',
  'WAITING_FOR_APPROVAL',
  'WAITING_FOR_USER',
  'COMPLETED',
  'FAILED',
  'CANCELLED',
];
const List<String> terminalStates = ['COMPLETED', 'FAILED', 'CANCELLED'];

const List<String> commandOutcomes = ['pending', 'ok', 'failed', 'unknown'];

/// Raised on an illegal state transition (e.g. mutating a terminal run).
class RunStateError implements Exception {
  RunStateError(this.message);
  final String message;

  @override
  String toString() => 'RunStateError: $message';
}

class Command {
  Command({
    required this.id,
    required this.capabilityName,
    required this.arguments,
    required this.retrySafety,
    this.outcome = 'pending',
    this.attempts = 0,
    this.resultRef,
    this.error,
  });

  final String id;
  final String capabilityName;
  final Map<String, Object?> arguments;
  final String retrySafety;
  String outcome;
  int attempts;
  String? resultRef; // artifact id, when ok
  String? error;

  factory Command.newCommand(
          String capabilityName, Map<String, Object?> arguments, String retrySafety) =>
      Command(
        id: newId('command'),
        capabilityName: capabilityName,
        arguments: arguments,
        retrySafety: retrySafety,
      );
}

class ApprovalRequest {
  ApprovalRequest({
    required this.id,
    required this.commandId,
    required this.effects,
    required this.reason,
    required this.policyRevision,
    this.expiresAt,
    this.resolution, // "approved" | "denied" | "expired" | null (pending)
    this.resolvedAt,
  });

  final String id;
  final String commandId;
  final List<Effect> effects;
  final String reason;
  final int policyRevision;
  double? expiresAt;
  String? resolution;
  double? resolvedAt;

  bool isExpired({double? now}) {
    final t = now ?? DateTime.now().millisecondsSinceEpoch / 1000.0;
    return expiresAt != null && t >= expiresAt!;
  }
}

/// What a handler returns to pause the run until the user answers
/// (see the `ask` pack). The runtime turns it into a [PendingQuestion].
class Question {
  Question(this.text, {this.choices});
  final String text;
  final List<String>? choices;
}

/// A question the run is waiting on, persisted in the snapshot so the pause
/// survives a restart. `Session.answer` fills [answer] and resumes.
class PendingQuestion {
  PendingQuestion({
    required this.id,
    required this.commandId,
    required this.callId,
    required this.text,
    this.choices,
    this.answer,
  });

  final String id;
  final String commandId;
  final String callId;
  final String text;
  final List<String>? choices;
  String? answer;

  Map<String, Object?> toMap() => {
        'id': id,
        'command_id': commandId,
        'call_id': callId,
        'text': text,
        'choices': choices,
        'answer': answer,
      };

  factory PendingQuestion.fromMap(Map<String, Object?> m) => PendingQuestion(
        id: m['id'] as String,
        commandId: m['command_id'] as String,
        callId: m['call_id'] as String,
        text: m['text'] as String,
        choices: (m['choices'] as List?)?.cast<String>(),
        answer: m['answer'] as String?,
      );
}

double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

/// The state machine for one execution. Every transition and approval event
/// is written to the ledger *before* [state] is updated, so a crash between
/// the write and the in-memory update is self-healing on replay (the
/// ledger, not the object, is the source of truth).
class Run {
  Run(this.id, this.sessionId, this.ledger);

  final String id;
  final String sessionId;
  final EventLedger ledger;
  String state = 'RUNNING';
  final Map<String, Command> commands = {};
  ApprovalRequest? pendingApproval;
  // Kept around after resolveApproval() clears pendingApproval, so resume
  // can find the exact command id that was approved instead of minting a
  // fresh one: an approved command must keep its idempotency key across the
  // pause. The runtime clears it once consumed.
  ApprovalRequest? lastResolvedApproval;
  PendingQuestion? pendingQuestion;
  List<ToolCall> pendingCalls = [];
  Object? result;

  // -- state transitions ------------------------------------------------

  void _assertNotTerminal() {
    if (terminalStates.contains(state)) {
      throw RunStateError('Run $id is terminal ($state); no further commands may execute');
    }
  }

  void transition(String newState, {String reason = ''}) {
    if (!runStates.contains(newState)) {
      throw ArgumentError('Unknown run state "$newState"');
    }
    if (terminalStates.contains(state) && newState != state) {
      throw RunStateError('Run $id is terminal ($state); cannot transition to $newState');
    }
    ledger.append(id, 'run_state_changed', {'from': state, 'to': newState, 'reason': reason});
    state = newState;
  }

  void complete(Object? result) {
    this.result = result;
    transition('COMPLETED', reason: 'finish');
  }

  void fail(String reason) => transition('FAILED', reason: reason);

  void cancel([String reason = 'cancelled']) => transition('CANCELLED', reason: reason);

  // -- commands -----------------------------------------------------------

  Command newCommand(String capabilityName, Map<String, Object?> arguments, String retrySafety) {
    _assertNotTerminal();
    final cmd = Command.newCommand(capabilityName, arguments, retrySafety);
    commands[cmd.id] = cmd;
    ledger.append(id, 'command_started',
        {'command_id': cmd.id, 'capability': capabilityName, 'arguments': arguments});
    return cmd;
  }

  void recordOutcome(Command command, String outcome, {String? error, String? resultRef}) {
    if (!commandOutcomes.contains(outcome)) {
      throw ArgumentError('Unknown command outcome "$outcome"');
    }
    command.outcome = outcome;
    command.error = error;
    command.resultRef = resultRef;
    const eventTypeFor = {
      'ok': 'command_completed',
      'failed': 'command_failed',
      'unknown': 'command_outcome_unknown',
    };
    ledger.append(id, eventTypeFor[outcome]!,
        {'command_id': command.id, 'error': error, 'result_ref': resultRef});
  }

  // -- approval -------------------------------------------------------------

  ApprovalRequest requestApproval(
    Command command,
    List<Effect> effects,
    String reason, {
    required int policyRevision,
    double? expiresInS,
  }) {
    final expiresAt = expiresInS != null ? _nowSeconds() + expiresInS : null;
    final request = ApprovalRequest(
      id: newId('approval'),
      commandId: command.id,
      effects: effects,
      reason: reason,
      policyRevision: policyRevision,
      expiresAt: expiresAt,
    );
    pendingApproval = request;
    ledger.append(id, 'approval_requested', {
      'approval_id': request.id,
      'command_id': command.id,
      'reason': reason,
      'effects': [for (final e in effects) {'kind': e.kind, 'resource': e.resource}],
      'policy_revision': policyRevision,
      'expires_at': expiresAt,
    });
    transition('WAITING_FOR_APPROVAL', reason: reason);
    return request;
  }

  /// Resolve the pending approval. `decision` is 'approved' or 'denied'. If
  /// the policy revision has moved since the request was made, the approval
  /// is stale and must be re-requested — approving blind to a changed
  /// policy would defeat the whole point of layered deny (the "premise
  /// changed" rule).
  ApprovalRequest resolveApproval(String decision, {required int currentPolicyRevision}) {
    final request = pendingApproval;
    if (request == null) {
      throw RunStateError('Run $id has no pending approval to resolve');
    }
    if (request.isExpired()) {
      request.resolution = 'expired';
      ledger.append(id, 'approval_resolved', {'approval_id': request.id, 'resolution': 'expired'});
      throw RunStateError('Approval ${request.id} expired at ${request.expiresAt}');
    }
    if (currentPolicyRevision != request.policyRevision) {
      throw RunStateError(
          'Policy changed (revision ${request.policyRevision} -> $currentPolicyRevision) '
          'since approval ${request.id} was requested; re-evaluate before resolving');
    }
    if (decision != 'approved' && decision != 'denied') {
      throw ArgumentError("decision must be 'approved' or 'denied'");
    }
    request.resolution = decision;
    request.resolvedAt = _nowSeconds();
    ledger.append(id, 'approval_resolved', {'approval_id': request.id, 'resolution': decision});
    pendingApproval = null;
    lastResolvedApproval = request;
    // pendingCalls is intentionally left intact on denial: the runtime's
    // resume path consumes it to tell the model *why* nothing ran, then
    // clears it — dropping it here would silently swallow that context.
    transition('RUNNING', reason: 'approval $decision');
    return request;
  }

  // -- questions ------------------------------------------------------------

  /// Park the run on a question the model asked the user (the `ask` pack).
  PendingQuestion askQuestion(Command command, String callId, Question question) {
    final pending = PendingQuestion(
      id: newId('question'),
      commandId: command.id,
      callId: callId,
      text: question.text,
      choices: question.choices,
    );
    pendingQuestion = pending;
    ledger.append(id, 'question_asked', {
      'question_id': pending.id,
      'command_id': command.id,
      'call_id': callId,
      'text': question.text,
      'choices': question.choices,
    });
    transition('WAITING_FOR_USER', reason: 'question');
    return pending;
  }

  /// Answer the pending question; the asking command completes with the
  /// answer as its result and the run is `RUNNING` again.
  PendingQuestion answer(String text) {
    final pending = pendingQuestion;
    if (pending == null) {
      throw RunStateError('Run $id has no pending question to answer');
    }
    pending.answer = text;
    ledger.append(id, 'question_answered', {'question_id': pending.id, 'answer': text});
    recordOutcome(commands[pending.commandId]!, 'ok');
    pendingQuestion = null;
    transition('RUNNING', reason: 'answered');
    return pending;
  }

  // -- persistence snapshot ------------------------------------------------

  Map<String, Object?> toSnapshotState() => {
        'session_id': sessionId,
        'state': state,
        'result': result,
        'commands': {
          for (final entry in commands.entries)
            entry.key: {
              'capability_name': entry.value.capabilityName,
              'arguments': entry.value.arguments,
              'retry_safety': entry.value.retrySafety,
              'outcome': entry.value.outcome,
              'attempts': entry.value.attempts,
              'result_ref': entry.value.resultRef,
              'error': entry.value.error,
            },
        },
        'pending_approval': pendingApproval == null
            ? null
            : {
                'id': pendingApproval!.id,
                'command_id': pendingApproval!.commandId,
                'reason': pendingApproval!.reason,
                'effects': [
                  for (final e in pendingApproval!.effects)
                    {'kind': e.kind, 'resource': e.resource},
                ],
                'policy_revision': pendingApproval!.policyRevision,
                'expires_at': pendingApproval!.expiresAt,
              },
        'pending_question': pendingQuestion?.toMap(),
        'pending_calls': [
          for (final c in pendingCalls)
            {'id': c.id, 'name': c.name, 'arguments': c.arguments, 'raw_arguments': c.rawArguments},
        ],
        'last_resolved_approval': lastResolvedApproval == null
            ? null
            : {
                'id': lastResolvedApproval!.id,
                'command_id': lastResolvedApproval!.commandId,
                'resolution': lastResolvedApproval!.resolution,
              },
      };

  factory Run.fromSnapshotState(String runId, EventLedger ledger, Map<String, Object?> state) {
    final run = Run(runId, state['session_id'] as String, ledger);
    run.state = state['state'] as String;
    run.result = state['result'];
    final commandsMap = (state['commands'] as Map?)?.cast<String, Object?>() ?? {};
    for (final entry in commandsMap.entries) {
      final c = (entry.value as Map).cast<String, Object?>();
      run.commands[entry.key] = Command(
        id: entry.key,
        capabilityName: c['capability_name'] as String,
        arguments: (c['arguments'] as Map).cast<String, Object?>(),
        retrySafety: c['retry_safety'] as String,
        outcome: c['outcome'] as String,
        attempts: (c['attempts'] as num).toInt(),
        resultRef: c['result_ref'] as String?,
        error: c['error'] as String?,
      );
    }
    final pa = (state['pending_approval'] as Map?)?.cast<String, Object?>();
    if (pa != null) {
      run.pendingApproval = ApprovalRequest(
        id: pa['id'] as String,
        commandId: pa['command_id'] as String,
        effects: [
          for (final e in (pa['effects'] as List))
            Effect(
              kind: (e as Map)['kind'] as String,
              resource: e['resource'] as String,
            ),
        ],
        reason: pa['reason'] as String,
        policyRevision: (pa['policy_revision'] as num).toInt(),
        expiresAt: (pa['expires_at'] as num?)?.toDouble(),
      );
    }
    final pq = (state['pending_question'] as Map?)?.cast<String, Object?>();
    if (pq != null) run.pendingQuestion = PendingQuestion.fromMap(pq);
    run.pendingCalls = [
      for (final c in (state['pending_calls'] as List? ?? []))
        ToolCall(
          id: (c as Map)['id'] as String,
          name: c['name'] as String,
          arguments: (c['arguments'] as Map).cast<String, Object?>(),
          rawArguments: c['raw_arguments'] as String?,
        ),
    ];
    final lra = (state['last_resolved_approval'] as Map?)?.cast<String, Object?>();
    if (lra != null) {
      run.lastResolvedApproval = ApprovalRequest(
        id: lra['id'] as String,
        commandId: lra['command_id'] as String,
        effects: [],
        reason: '',
        policyRevision: 0,
        resolution: lra['resolution'] as String?,
      );
    }
    return run;
  }
}
