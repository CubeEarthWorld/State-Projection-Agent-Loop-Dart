/// Structured working state: a finite, typed record of what the agent knows
/// and has decided, replacing an unbounded stack of free-text summaries.
///
/// The old summary contract asked an LLM to write prose that "preserves
/// reasons" and hoped later re-folds wouldn't lose them. Prose has no
/// schema, so nothing enforced that promise — a decision's reason was
/// exactly as likely to survive a second fold as any other sentence, which
/// is to say: not reliably. [WorkingState] makes the shape the promise:
/// decisions are `(text, reason)` pairs in a list, not sentences buried in a
/// paragraph, so folding *appends* to a field instead of re-summarizing a
/// summary.
///
/// The original conversation text is never lost either way — it stays in
/// the Event Ledger (`user_input`/`model_response`/`command_*` events) and
/// is reachable via the `search_history` capability even after being folded
/// out of the live projection.
library;

import 'dart:convert';

import 'messages.dart';
import 'tokens.dart';

class RecordedDecision {
  RecordedDecision({required this.text, this.reason = ''});

  final String text;
  final String reason;

  Map<String, String> toDict() => {'text': text, 'reason': reason};

  factory RecordedDecision.fromDict(Map<String, Object?> d) => RecordedDecision(
        text: (d['text'] ?? '').toString(),
        reason: (d['reason'] ?? '').toString(),
      );
}

class WorkingState {
  WorkingState({
    this.goal = '',
    List<String>? acceptanceCriteria,
    List<String>? constraints,
    List<String>? confirmedFacts,
    List<RecordedDecision>? decisions,
    List<String>? openQuestions,
    List<String>? nextActions,
    List<String>? artifactRefs,
    Map<String, Object?>? extra,
  })  : acceptanceCriteria = acceptanceCriteria ?? <String>[],
        constraints = constraints ?? <String>[],
        confirmedFacts = confirmedFacts ?? <String>[],
        decisions = decisions ?? <RecordedDecision>[],
        openQuestions = openQuestions ?? <String>[],
        nextActions = nextActions ?? <String>[],
        artifactRefs = artifactRefs ?? <String>[],
        extra = extra ?? <String, Object?>{};

  String goal;
  final List<String> acceptanceCriteria;
  final List<String> constraints;
  final List<String> confirmedFacts;
  final List<RecordedDecision> decisions;
  List<String> openQuestions;
  List<String> nextActions;
  final List<String> artifactRefs;
  // Free-form escape hatch for application-specific state (game flags,
  // domain variables) that doesn't fit the fixed fields above. Editors of
  // `extra` are the same three as before: user code, the LLM (via the
  // state.extra.* capabilities), and the session seed.
  final Map<String, Object?> extra;

  bool isEmpty() =>
      goal.isEmpty &&
      acceptanceCriteria.isEmpty &&
      constraints.isEmpty &&
      confirmedFacts.isEmpty &&
      decisions.isEmpty &&
      openQuestions.isEmpty &&
      nextActions.isEmpty &&
      artifactRefs.isEmpty &&
      extra.isEmpty;

  Map<String, Object?> toDict() => {
        'goal': goal,
        'acceptance_criteria': List<String>.from(acceptanceCriteria),
        'constraints': List<String>.from(constraints),
        'confirmed_facts': List<String>.from(confirmedFacts),
        'decisions': [for (final d in decisions) d.toDict()],
        'open_questions': List<String>.from(openQuestions),
        'next_actions': List<String>.from(nextActions),
        'artifact_refs': List<String>.from(artifactRefs),
        'extra': Map<String, Object?>.from(extra),
      };

  factory WorkingState.fromDict(Map<String, Object?> d) => WorkingState(
        goal: (d['goal'] ?? '').toString(),
        acceptanceCriteria: ((d['acceptance_criteria'] as List?) ?? []).cast<String>(),
        constraints: ((d['constraints'] as List?) ?? []).cast<String>(),
        confirmedFacts: ((d['confirmed_facts'] as List?) ?? []).cast<String>(),
        decisions: [
          for (final x in (d['decisions'] as List? ?? []))
            RecordedDecision.fromDict((x as Map).cast<String, Object?>()),
        ],
        openQuestions: ((d['open_questions'] as List?) ?? []).cast<String>(),
        nextActions: ((d['next_actions'] as List?) ?? []).cast<String>(),
        artifactRefs: ((d['artifact_refs'] as List?) ?? []).cast<String>(),
        extra: (d['extra'] as Map?)?.cast<String, Object?>() ?? {},
      );

  String render({int maxTokens = 800}) {
    final parts = <String>[];
    if (goal.isNotEmpty) parts.add('goal: $goal');
    if (acceptanceCriteria.isNotEmpty) {
      parts.add('acceptance_criteria:\n${acceptanceCriteria.map((c) => '- $c').join('\n')}');
    }
    if (constraints.isNotEmpty) {
      parts.add('constraints:\n${constraints.map((c) => '- $c').join('\n')}');
    }
    if (confirmedFacts.isNotEmpty) {
      parts.add('confirmed_facts:\n${confirmedFacts.map((c) => '- $c').join('\n')}');
    }
    if (decisions.isNotEmpty) {
      parts.add('decisions:\n${decisions.map((d) => '- ${d.text}${d.reason.isNotEmpty ? ' (because: ${d.reason})' : ''}').join('\n')}');
    }
    if (openQuestions.isNotEmpty) {
      parts.add('open_questions:\n${openQuestions.map((q) => '- $q').join('\n')}');
    }
    if (nextActions.isNotEmpty) {
      parts.add('next_actions:\n${nextActions.map((a) => '- $a').join('\n')}');
    }
    if (artifactRefs.isNotEmpty) {
      parts.add('artifact_refs: ${artifactRefs.join(', ')}');
    }
    if (extra.isNotEmpty) {
      parts.add('extra: ${jsonEncode(extra)}');
    }
    var body = parts.join('\n');
    if (estimateTokens(body) > maxTokens) {
      // Truncate the least time-critical sections first: facts, then
      // decisions, keeping goal/constraints/open_questions/next_actions
      // (the parts most load-bearing for not losing the thread).
      final cutoff = maxTokens * 4;
      body = body.length > cutoff ? body.substring(0, cutoff) : body;
    }
    return body;
  }
}

/// Projects the working state each turn (volatile — always near the tail).
class WorkingStateSection {
  WorkingStateSection({this.maxTokens = 800});

  final String name = 'working_state';
  final String cacheClass = 'volatile';
  final int maxTokens;

  List<Message> render(Object? turn) {
    final ws = (turn as dynamic).workingState as WorkingState?;
    if (ws == null || ws.isEmpty()) return const [];
    return [
      Message(
        role: kSystem,
        content: '[Working state]\n${ws.render(maxTokens: maxTokens)}',
      ),
    ];
  }
}
