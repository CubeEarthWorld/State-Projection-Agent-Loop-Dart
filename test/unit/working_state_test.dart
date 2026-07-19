// WorkingState: structured merge semantics (decisions keep their reason
// through repeated folds — P1-1), rendering, round-trip serialization.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
  group('MergeFold', () {
    test('facts are additive and deduped', () {
      final ws = WorkingState();
      ws.mergeFold({
        'new_facts': ['user wants JSON output'],
      });
      ws.mergeFold({
        'new_facts': ['user wants JSON output', 'user is on Windows'],
      });
      expect(ws.confirmedFacts, equals(['user wants JSON output', 'user is on Windows']));
    });

    test('decisions keep reason across repeated folds', () {
      final ws = WorkingState();
      ws.mergeFold({
        'new_decisions': [
          {'text': 'used SQLite', 'reason': 'no server needed for this scale'},
        ],
      });
      ws.mergeFold({
        'new_decisions': [
          {'text': 'added an index on user_id', 'reason': 'query was slow'},
        ],
      });
      expect(ws.decisions.length, equals(2));
      expect(ws.decisions[0].reason, equals('no server needed for this scale'));
      expect(ws.decisions[1].reason, equals('query was slow'));
    });

    test('open questions add and resolve', () {
      final ws = WorkingState();
      ws.mergeFold({
        'new_open_questions': ['which timezone?'],
      });
      expect(ws.openQuestions, equals(['which timezone?']));
      ws.mergeFold({
        'resolved_open_questions': ['which timezone?'],
      });
      expect(ws.openQuestions, equals(<String>[]));
    });

    test('next actions replaced not appended', () {
      final ws = WorkingState();
      ws.mergeFold({
        'next_actions': ['step 1', 'step 2'],
      });
      ws.mergeFold({
        'next_actions': ['step 3'],
      });
      expect(ws.nextActions, equals(['step 3']));
    });

    test('goal only updated when present', () {
      final ws = WorkingState(goal: 'original goal');
      ws.mergeFold({
        'new_facts': ['irrelevant'],
      });
      expect(ws.goal, equals('original goal'));
      ws.mergeFold({'goal': 'revised goal'});
      expect(ws.goal, equals('revised goal'));
    });
  });

  group('RenderAndSerialize', () {
    test('render includes decision reason', () {
      final ws = WorkingState(
        decisions: [RecordedDecision(text: 'chose X', reason: 'Y was slower')],
      );
      final text = ws.render();
      expect(text, contains('chose X'));
      expect(text, contains('Y was slower'));
    });

    test('isEmpty', () {
      expect(WorkingState().isEmpty(), isTrue);
      expect(WorkingState(goal: 'x').isEmpty(), isFalse);
      expect(WorkingState(extra: {'flag': true}).isEmpty(), isFalse);
    });

    test('round trip', () {
      final ws = WorkingState(
        goal: 'g',
        acceptanceCriteria: ['a'],
        constraints: ['c'],
        confirmedFacts: ['f'],
        decisions: [RecordedDecision(text: 'd', reason: 'r')],
        openQuestions: ['q'],
        nextActions: ['n'],
        artifactRefs: ['art_1'],
        extra: {'k': 'v'},
      );
      final restored = WorkingState.fromDict(ws.toDict());
      expect(restored.toDict(), equals(ws.toDict()));
    });
  });
}
