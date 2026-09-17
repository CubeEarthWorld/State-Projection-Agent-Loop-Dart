// WorkingState: rendering, round-trip serialization.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
  group('RenderAndSerialize', () {
    test('render includes decision reason', () {
      final ws = WorkingState(
        decisions: [RecordedDecision(text: 'chose X', reason: 'Y was slower')],
      );
      final text = ws.render();
      expect(text, contains('chose X'));
      expect(text, contains('Y was slower'));
    });

    test('render keeps a Japanese state inside its token budget', () {
      final ws = WorkingState(confirmedFacts: List.filled(10, '在庫は東京倉庫にある' * 40));
      expect(estimateTokens(ws.render(maxTokens: 200)), lessThanOrEqualTo(200));
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
