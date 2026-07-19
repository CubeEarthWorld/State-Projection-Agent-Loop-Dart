// Compactor: split point safety (never orphans observations), fold
// contract v2 JSON delta parsing, deterministic fallback.
//
// NOTE: Python's `_parse_delta` is a private module function tested
// directly; Dart's equivalent is a private top-level function in
// compaction.dart and is not reachable from an external test file (Dart
// privacy is library-file scoped). Its behavior is exercised indirectly
// here via `Compactor.fold` with a `ScriptedLLM` summarizer instead, which
// covers exactly the same parsing paths (plain JSON / fenced JSON /
// malformed text) through the public API.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
  group('ParseDelta (via Compactor.fold + ScriptedLLM summarizer)', () {
    test('parses plain json', () async {
      final summarizer = ScriptedLLM([const TextStep('{"new_facts": ["a"]}')]);
      final compactor = Compactor(Config(), summarizer: summarizer);
      final ws = WorkingState();
      final conversation = [Message(role: kUser, content: 'x'), Message(role: kUser, content: 'y')];
      final (folded, _) = await compactor.fold(conversation, ws);
      expect(folded, isTrue);
      expect(ws.confirmedFacts, equals(['a']));
    });

    test('parses fenced json', () async {
      final summarizer =
          ScriptedLLM([const TextStep('```json\n{"new_facts": ["a"]}\n```')]);
      final compactor = Compactor(Config(), summarizer: summarizer);
      final ws = WorkingState();
      final conversation = [Message(role: kUser, content: 'x'), Message(role: kUser, content: 'y')];
      final (folded, _) = await compactor.fold(conversation, ws);
      expect(folded, isTrue);
      expect(ws.confirmedFacts, equals(['a']));
    });

    test('malformed json becomes a fact not a crash', () async {
      final summarizer = ScriptedLLM([const TextStep('not json at all')]);
      final compactor = Compactor(Config(), summarizer: summarizer);
      final ws = WorkingState();
      final conversation = [Message(role: kUser, content: 'x'), Message(role: kUser, content: 'y')];
      final (folded, _) = await compactor.fold(conversation, ws);
      expect(folded, isTrue);
      expect(ws.confirmedFacts.length, equals(1));
      expect(ws.confirmedFacts.first, contains('not json'));
    });
  });

  group('SplitPoint', () {
    test('never splits inside a tool call pair', () {
      final compactor = Compactor(Config());
      final conversation = <Message>[];
      for (var i = 0; i < 6; i++) {
        conversation.add(Message(
          role: kAssistant,
          content: 'step $i',
          toolCalls: [ToolCall(name: 't', arguments: {})],
        ));
        conversation.add(Message(
          role: kObservation,
          content: 'result',
          toolCallId: 'c$i',
          name: 't',
        ));
      }
      final i = compactor.splitPoint(conversation);
      expect(conversation[i].role, isNot(equals(kObservation))); // never orphans an observation at the head
    });
  });

  group('Fold', () {
    test('deterministic fold used when no summarizer', () async {
      // splitPoint always leaves at least the last exchange unfolded, so
      // a lone message never folds — use enough turns that a genuine
      // older half exists to fold away.
      final compactor = Compactor(Config());
      final ws = WorkingState();
      final conversation = [
        Message(role: kUser, content: 'please remember X${' pad' * 20}'),
        for (var i = 0; i < 5; i++) Message(role: kAssistant, content: 'reply $i${' pad' * 20}'),
      ];
      final (folded, remaining) = await compactor.fold(conversation, ws);
      expect(folded, isTrue);
      expect(ws.confirmedFacts.any((f) => f.contains('please remember X')), isTrue);
      expect(remaining.length, lessThan(conversation.length));
    });

    test('fold merges summarizer json delta', () async {
      final summarizer =
          ScriptedLLM([const TextStep('{"new_facts": ["the user prefers dark mode"]}')]);
      final compactor = Compactor(Config(), summarizer: summarizer);
      final ws = WorkingState();
      final conversation = [
        Message(role: kUser, content: 'I like dark mode'),
        Message(role: kUser, content: 'I like dark mode'),
      ];
      final (folded, _) = await compactor.fold(conversation, ws);
      expect(folded, isTrue);
      expect(ws.confirmedFacts, contains('the user prefers dark mode'));
    });

    test('empty conversation does not fold', () async {
      final compactor = Compactor(Config());
      final ws = WorkingState();
      final (folded, _) = await compactor.fold([], ws);
      expect(folded, isFalse);
      expect(ws.isEmpty(), isTrue);
    });

    test('deterministic fold helper direct', () {
      final conversation = [
        Message(role: kUser, content: 'hi'),
        Message(
          role: kAssistant,
          content: '',
          toolCalls: [ToolCall(name: 'demo.tool', arguments: {})],
        ),
      ];
      final delta = deterministicFold(conversation);
      final facts = (delta['new_facts'] as List).cast<String>();
      expect(facts.any((f) => f.contains('hi')), isTrue);
    });
  });
}
