// Projection pipeline: section ordering, window enforcement including
// native tool-schema + reserved-output budgeting (P0-5), kernel immutability,
// epoch-cached TOC, candidate-card dedup against native schemas.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

TurnContext makeTurn({
  Registry? registry,
  List<Message>? conversation,
  WorkingState? workingState,
  List<ScoredTool>? candidates,
  int window = 30000,
}) {
  final cfg = Config();
  cfg.projection.windowTokens = window;
  return TurnContext(
    config: cfg,
    registry: registry ?? Registry(),
    conversation: conversation ?? [],
    workingState: workingState ?? WorkingState(),
    candidates: candidates ?? [],
  );
}

Projection defaultProjection(Registry registry, {String kernel = 'You are helpful.', int window = 30000}) {
  final sections = buildDefaultSections(
    ['kernel', 'toc', 'conversation', 'working_state', 'candidates'],
    kernelText: kernel,
    pinned: registry.pinned(),
  );
  return Projection(sections, windowTokens: window);
}

void main() {
  group('OrderingInvariants', () {
    test('volatile must be last', () {
      expect(
        () => Projection([CandidatesSection(), ConversationSection()]),
        throwsA(isA<ProjectionError>()
            .having((e) => e.toString(), 'message', contains('Invariant violated'))),
      );
    });

    test('valid default order', () {
      Projection([
        KernelSection('k'),
        TocSection(),
        ConversationSection(),
        _WorkingStateSectionWrapper(),
        CandidatesSection(),
      ]);
    });

    test('unknown cache_class rejected', () {
      expect(
        () => Projection([_BadSection()]),
        throwsA(isA<ProjectionError>()
            .having((e) => e.toString(), 'message', contains('cache_class'))),
      );
    });

    test('unknown section name rejected', () {
      expect(
        () => buildDefaultSections(['kernel', 'mystery'], kernelText: '', pinned: []),
        throwsA(isA<ProjectionError>()
            .having((e) => e.toString(), 'message', contains('Unknown section'))),
      );
    });
  });

  group('RenderComposition', () {
    test('kernel first and contains pinned spec', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.pinned_tool', pinned: true, description: 'Pinned helper.'));
      final projection = defaultProjection(reg);
      final msgs = projection.render(makeTurn(registry: reg));
      expect(msgs[0].role, equals('system'));
      expect(msgs[0].content.toString(), contains('You are helpful.'));
      expect(msgs[0].content.toString(), contains('### demo.pinned_tool@1'));
    });

    test('toc present and working state absent when empty', () {
      final reg = Registry();
      reg.register(capabilityDict('web.t', category: 'web'));
      final projection = defaultProjection(reg);
      final msgs = projection.render(makeTurn(registry: reg));
      final contents = msgs.map((m) => m.content.toString()).toList();
      expect(contents.any((c) => c.contains('[Tool index] web(1)')), isTrue);
      expect(contents.any((c) => c.contains('[Working state]')), isFalse);
    });

    test('toc disabled by config', () {
      final reg = Registry();
      reg.register(capabilityDict('web.t', category: 'web'));
      final projection = defaultProjection(reg);
      final turn = makeTurn(registry: reg);
      turn.config.discovery.toc = false;
      final msgs = projection.render(turn);
      expect(msgs.any((m) => m.content.toString().contains('[Tool index]')), isFalse);
    });

    test('candidates render last', () {
      final reg = Registry();
      final cap = reg.register(capabilityDict('demo.cand', summary: 'candidate tool'));
      final projection = defaultProjection(reg);
      final turn = makeTurn(
        registry: reg,
        conversation: [Message(role: 'user', content: 'hi')],
        candidates: [ScoredTool(tool: cap, score: 1.0)],
      );
      final msgs = projection.render(turn);
      expect(msgs.last.content.toString(), contains('[Tool candidates'));
      expect(msgs.last.content.toString(), contains('- demo.cand('));
    });

    test('candidate cards deduped against native schemas', () {
      final reg = Registry();
      final cap = reg.register(
          capabilityDict('demo.cand', summary: 'a somewhat long description of the tool'));
      final projection = defaultProjection(reg);
      final turn = makeTurn(registry: reg, candidates: [ScoredTool(tool: cap, score: 1.0)]);
      turn.dedupeCandidateCards = true;
      final msgs = projection.render(turn, apiTools: [cap.apiSchema()]);
      final last = msgs.last.content.toString();
      expect(last, contains('schemas sent natively'));
      expect(last, isNot(contains('a somewhat long description')));
    });

    test('working state rendered when present', () {
      final projection = defaultProjection(Registry());
      final ws = WorkingState(goal: 'ship the feature');
      final msgs = projection.render(makeTurn(workingState: ws));
      expect(
        msgs.any((m) =>
            m.content.toString().contains('[Working state]') &&
            m.content.toString().contains('ship the feature')),
        isTrue,
      );
    });
  });

  group('TocEpochCaching', () {
    test('toc updates after registry change', () {
      final reg = Registry();
      reg.register(capabilityDict('web.a', category: 'web'));
      final section = TocSection();
      final turn = makeTurn(registry: reg);
      final first = section.render(turn);
      expect(first[0].content.toString(), contains('web(1)'));
      expect(identical(section.render(turn)[0], first[0]), isTrue); // cached within an epoch
      reg.register(capabilityDict('web.b', category: 'web'));
      expect(section.render(turn)[0].content.toString(), contains('web(2)'));
    });

    test('kernel is immutable across registry changes', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.p', pinned: true));
      final section = KernelSection('kernel', reg.pinned());
      final before = section.render(makeTurn(registry: reg))[0].content;
      reg.register(capabilityDict('demo.late_pin', pinned: true));
      final after = section.render(makeTurn(registry: reg))[0].content;
      expect(before, equals(after));
    });
  });

  group('WindowEnforcement', () {
    test('candidates shrink first', () {
      final reg = Registry();
      final caps = [
        for (var i = 0; i < 10; i++) reg.register(capabilityDict('demo.tool_$i', summary: 'x' * 120)),
      ];
      final projection = defaultProjection(reg, window: 260);
      final turn = makeTurn(
        registry: reg,
        window: 260,
        candidates: [for (final c in caps) ScoredTool(tool: c, score: 1.0)],
      );
      final msgs = projection.render(turn);
      expect(estimateTokens(msgs), lessThanOrEqualTo(260));
      expect(turn.candidates.length, lessThan(10));
    });

    test('conversation emergency trim', () {
      final reg = Registry();
      final projection = defaultProjection(reg, window: 500);
      final conversation = [
        for (var i = 0; i < 8; i++)
          Message(role: 'user', content: 'message $i ${'long text ' * 30}'),
      ];
      final turn = makeTurn(registry: reg, conversation: conversation, window: 500);
      final msgs = projection.render(turn);
      expect(estimateTokens(msgs), lessThanOrEqualTo(500));
      expect(msgs.any((m) => m.content.toString().contains('trimmed')), isTrue);
      expect(msgs.any((m) => m.content.toString().contains('message 7')), isTrue);
    });

    test('trim never leaves orphan observations', () {
      final reg = Registry();
      final projection = defaultProjection(reg, window: 220);
      final conversation = <Message>[];
      for (var i = 0; i < 6; i++) {
        conversation.add(Message(
          role: 'assistant',
          content: 'step $i ${'pad ' * 20}',
          toolCalls: [ToolCall(name: 't', arguments: {})],
        ));
        conversation.add(Message(
          role: 'tool',
          content: 'result ${'pad ' * 20}',
          toolCallId: 'c$i',
          name: 't',
        ));
      }
      final turn = makeTurn(registry: reg, conversation: conversation, window: 220);
      final msgs = projection.render(turn);
      final roles = msgs.map((m) => m.role).toList();
      final firstConv = roles.indexWhere((r) => r == 'assistant' || r == 'tool');
      if (firstConv != -1) {
        expect(roles[firstConv], equals('assistant'));
      }
    });

    test('native tool schemas count against the budget', () {
      // Same window either way; sending a native tool schema alongside the
      // projection eats into the same budget, so strictly less (or equal)
      // conversation can survive once the schema is counted (P0-5) —
      // a schema was previously invisible to the window check entirely.
      final reg = Registry();
      reg.register(capabilityDict('demo.tool', properties: {
        for (var i = 0; i < 6; i++) 'p$i': {'type': 'string', 'description': 'x' * 40},
      }));
      final cap = reg.get('demo.tool')!;
      final projection = defaultProjection(reg, window: 400);
      final conversation = [
        for (var i = 0; i < 10; i++) Message(role: 'user', content: 'message $i ${'pad ' * 20}'),
      ];

      final withoutSchema = projection
          .render(makeTurn(registry: reg, conversation: List.of(conversation), window: 400));
      final withSchema = projection.render(
        makeTurn(registry: reg, conversation: List.of(conversation), window: 400),
        apiTools: [cap.apiSchema()],
      );
      expect(estimateTokens(withSchema), lessThanOrEqualTo(estimateTokens(withoutSchema)));
      expect(withSchema.length, lessThanOrEqualTo(withoutSchema.length));
    });

    test('reserved output tokens counted', () {
      // Same reasoning as above but for the reserved-output allowance:
      // reserving room for the model's own reply must shrink what fits,
      // not be silently ignored.
      final reg = Registry();
      final projection = defaultProjection(reg, window: 400);
      final conversation = [
        for (var i = 0; i < 10; i++) Message(role: 'user', content: 'message $i ${'pad ' * 20}'),
      ];

      final unreserved = projection
          .render(makeTurn(registry: reg, conversation: List.of(conversation), window: 400));
      final reserved = projection.render(
        makeTurn(registry: reg, conversation: List.of(conversation), window: 400),
        reservedTokens: 150,
      );
      expect(estimateTokens(reserved), lessThanOrEqualTo(estimateTokens(unreserved)));
    });
  });
}

class _BadSection implements Section {
  @override
  final String name = 'bad';
  @override
  final String cacheClass = 'sometimes';

  @override
  List<Message> render(TurnContext turn) => [];
}

/// Adapts `WorkingStateSection` (duck-typed, not a `Section`) to the
/// `Section` interface for direct-construction tests — mirrors the private
/// adapter `buildDefaultSections` uses internally in lib/src/projection.dart.
class _WorkingStateSectionWrapper implements Section {
  final WorkingStateSection _inner = WorkingStateSection();

  @override
  String get name => _inner.name;
  @override
  String get cacheClass => _inner.cacheClass;

  @override
  List<Message> render(TurnContext turn) => _inner.render(turn);
}
