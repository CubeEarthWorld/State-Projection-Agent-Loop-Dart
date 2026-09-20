/// Structured working state: a finite, typed record of what the agent knows
/// and has decided, rather than an unbounded stack of free-text summaries.
///
/// Prose has no schema: a summary asked to "preserve reasons" keeps a
/// decision's reason exactly as reliably as any other sentence survives a
/// second fold, which is to say not reliably. [WorkingState] makes the shape
/// the promise: decisions are `(text, reason)` pairs in a list, not
/// sentences buried in a paragraph, so folding *appends* to a field instead
/// of re-summarizing a summary.
///
/// The original conversation text is never lost either way — it stays in
/// the Event Ledger (`user_input`/`model_response`/`command_*` events) and
/// is reachable via `meta.history.search` even after being folded
/// out of the live projection.
library;


import 'tokens.dart';
import 'checklists.dart';
import 'serialization.dart';

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
    ChecklistStore? checklists,
    this.foldedSequence = 0,
    this.verbatimSequence = 0,
  })  : acceptanceCriteria = acceptanceCriteria ?? <String>[],
        constraints = constraints ?? <String>[],
        confirmedFacts = confirmedFacts ?? <String>[],
        decisions = decisions ?? <RecordedDecision>[],
        openQuestions = openQuestions ?? <String>[],
        nextActions = nextActions ?? <String>[],
        artifactRefs = artifactRefs ?? <String>[],
        extra = extra ?? <String, Object?>{},
        checklists = checklists ?? ChecklistStore();

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
  // `extra` are user code, the LLM (via the state.extra.* capabilities) and
  // the session seed.
  final Map<String, Object?> extra;
  ChecklistStore checklists;
  // Ledger sequence up to which history has been folded into this state by
  // compaction; only the user's own words of those events render afterwards.
  int foldedSequence;
  // Ledger sequence from which history renders verbatim. Everything older is
  // tiered by its distance from this point, and the point moves only in
  // steps (see Session._stepTiers), so the rendered prefix stays
  // byte-identical between steps and a provider's prompt cache keeps hitting.
  int verbatimSequence;

  /// Empty when every field but the two sequence numbers is. Derived from
  /// [toDict] so the field list lives in one place; `checklists` is asked
  /// directly because its dict form is never empty.
  bool isEmpty() =>
      checklists.isEmpty &&
      toDict().entries.every((e) => switch (e.value) {
            String v => v.isEmpty,
            List v => v.isEmpty,
            Map v => e.key == 'checklists' || v.isEmpty,
            _ => true, // foldedSequence / verbatimSequence: never counted
          });

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
        'checklists': checklists.toDict(),
        'folded_sequence': foldedSequence,
        'verbatim_sequence': verbatimSequence,
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
        checklists: d.containsKey('checklists') ? ChecklistStore.fromDict(d['checklists']) : ChecklistStore(),
        foldedSequence: (d['folded_sequence'] as num?)?.toInt() ?? 0,
        verbatimSequence: (d['verbatim_sequence'] as num?)?.toInt() ?? 0,
      );

  String render({int maxTokens = 800}) {
    final parts = <String>[if (goal.isNotEmpty) 'goal: $goal'];
    void bullets(String name, Iterable<String> lines) {
      if (lines.isNotEmpty) parts.add('$name:\n${lines.map((line) => '- $line').join('\n')}');
    }

    bullets('acceptance_criteria', acceptanceCriteria);
    bullets('constraints', constraints);
    bullets('confirmed_facts', confirmedFacts);
    bullets('decisions', [
      for (final d in decisions) '${d.text}${d.reason.isNotEmpty ? ' (because: ${d.reason})' : ''}',
    ]);
    bullets('open_questions', openQuestions);
    bullets('next_actions', nextActions);
    if (artifactRefs.isNotEmpty) {
      parts.add('artifact_refs: ${artifactRefs.join(', ')}');
    }
    if (extra.isNotEmpty) {
      parts.add('extra: ${dumps(extra)}');
    }
    return truncateToTokens(parts.join('\n'), maxTokens);
  }
}

/// The typed fields of [WorkingState], i.e. the keys `fromDict` understands.
/// Anything else a caller seeds is app-specific state and belongs in `extra`.
///
/// Derived from `toDict` rather than spelled out again: a hand-kept copy that
/// drifts silently mis-routes a seeded key into `extra`.
final Set<String> workingStateFields = WorkingState().toDict().keys.toSet();
