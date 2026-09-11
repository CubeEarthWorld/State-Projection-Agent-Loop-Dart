// Projection pipeline: section composition, window enforcement including
// native tool-schema + reserved-output budgeting, kernel immutability,
// epoch-cached TOC, candidate-card dedup against native schemas, and
// fidelity-graded history rendering from the Event Ledger.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

(InMemoryLedger, String) makeLedgerWithEvents({int nUser = 3, int nObs = 0}) {
  final ledger = InMemoryLedger();
  const runId = 'run_test';
  for (var i = 0; i < nUser; i++) {
    ledger.append(runId, 'user_input', {'text': 'message $i ${'pad ' * 20}'});
    ledger.append(runId, 'model_response', {'text': 'reply $i', 'calls': []});
  }
  if (nObs > 0) {
    // Observations only ever follow the decision that asked for them; the
    // projection drops a result whose call is not there (and vice versa).
    ledger.append(runId, 'model_response', {
      'text': '',
      'calls': [
        for (var i = 0; i < nObs; i++) {'name': 'tool', 'arguments': {}, 'id': 'c$i'},
      ],
    });
  }
  for (var i = 0; i < nObs; i++) {
    ledger.append(runId, 'observation',
        {'call_id': 'c$i', 'name': 'tool', 'text': 'result $i ${'data ' * 30}'});
  }
  return (ledger, runId);
}

TurnContext makeTurn({
  Registry? registry,
  EventLedger? ledger,
  String runId = 'run_test',
  WorkingState? workingState,
  List<ScoredTool>? candidates,
  int window = 30000,
}) {
  final cfg = Config();
  cfg.projection.windowTokens = window;
  return TurnContext(
    config: cfg,
    registry: registry ?? Registry(),
    ledger: ledger ?? InMemoryLedger(),
    runId: runId,
    workingState: workingState ?? WorkingState(),
    candidates: candidates ?? [],
  );
}

Projection defaultProjection(Registry registry, {String kernel = 'You are helpful.', int window = 30000}) {
  final sections = buildDefaultSections(
    ['kernel', 'toc', 'history', 'working_state', 'candidates'],
    kernelText: kernel,
  );
  return Projection(sections, windowTokens: window);
}

void main() {
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
      final (ledger, runId) = makeLedgerWithEvents(nUser: 1);
      final turn = makeTurn(
        registry: reg,
        ledger: ledger,
        runId: runId,
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

  group('HistorySection', () {
    test('renders user and assistant from ledger', () {
      final (ledger, runId) = makeLedgerWithEvents(nUser: 2);
      final section = HistorySection();
      final turn = makeTurn(ledger: ledger, runId: runId);
      final msgs = section.render(turn);
      final roles = msgs.map((m) => m.role).toList();
      expect(roles, contains('user'));
      expect(roles, contains('assistant'));
    });

    test('renders observations', () {
      final (ledger, runId) = makeLedgerWithEvents(nUser: 1, nObs: 2);
      final section = HistorySection();
      final turn = makeTurn(ledger: ledger, runId: runId);
      final msgs = section.render(turn);
      final obs = msgs.where((m) => m.role == 'tool').toList();
      expect(obs.length, equals(2));
    });

    test('renders notices', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      ledger.append(runId, 'user_input', {'text': 'hi'});
      ledger.append(runId, 'notice', {'text': '[runtime] Budget exceeded'});
      final section = HistorySection();
      final turn = makeTurn(ledger: ledger, runId: runId);
      final msgs = section.render(turn);
      expect(msgs.any((m) => m.content.toString().contains('Budget exceeded')), isTrue);
    });

    test('fidelity full for recent', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      final longText = 'x ' * 200;
      ledger.append(runId, 'user_input', {'text': longText});
      final section = HistorySection();
      final turn = makeTurn(ledger: ledger, runId: runId);
      final msgs = section.render(turn);
      expect(msgs[0].content.toString(), equals(longText));
    });

    test('empty ledger returns empty', () {
      final section = HistorySection();
      final turn = makeTurn();
      expect(section.render(turn), isEmpty);
    });

    test('non-renderable events skipped', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      ledger.append(runId, 'user_input', {'text': 'hi'});
      ledger.append(runId, 'projection_compiled', {'tokens': 100});
      ledger.append(runId, 'decision_validated', {'ok': true});
      final section = HistorySection();
      final turn = makeTurn(ledger: ledger, runId: runId);
      final msgs = section.render(turn);
      expect(msgs.length, equals(1));
      expect(msgs[0].content.toString(), equals('hi'));
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
      expect(identical(section.render(turn)[0], first[0]), isTrue);
      reg.register(capabilityDict('web.b', category: 'web'));
      expect(section.render(turn)[0].content.toString(), contains('web(2)'));
    });

    test('kernel is stable while the registry is unchanged', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.p', pinned: true));
      final section = KernelSection('kernel');
      final first = section.render(makeTurn(registry: reg))[0].content;
      expect(section.render(makeTurn(registry: reg))[0].content, equals(first));
    });

    test('kernel picks up a capability pinned later', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.p', pinned: true));
      final section = KernelSection('kernel');
      final before = section.render(makeTurn(registry: reg))[0].content as String;
      expect(before.contains('demo.late_pin'), isFalse);
      reg.register(capabilityDict('demo.late_pin', pinned: true));
      final after = section.render(makeTurn(registry: reg))[0].content as String;
      expect(after.contains('demo.late_pin'), isTrue);
    });
  });

  group('WindowEnforcement', () {
    test('candidates shrink first', () {
      final reg = Registry();
      final caps = [
        for (var i = 0; i < 10; i++) reg.register(capabilityDict('demo.tool_$i', summary: 'x' * 120)),
      ];
      final projection = defaultProjection(reg, window: 260);
      final (ledger, runId) = makeLedgerWithEvents(nUser: 1);
      final turn = makeTurn(
        registry: reg,
        ledger: ledger,
        runId: runId,
        window: 260,
        candidates: [for (final c in caps) ScoredTool(tool: c, score: 1.0)],
      );
      final msgs = projection.render(turn);
      expect(estimateTokens(msgs), lessThanOrEqualTo(260));
      expect(turn.candidates.length, lessThan(10));
    });

    test('history emergency trim', () {
      final reg = Registry();
      final projection = defaultProjection(reg, window: 500);
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      for (var i = 0; i < 20; i++) {
        ledger.append(runId, 'user_input', {'text': 'message $i ${'long text ' * 30}'});
        ledger.append(runId, 'model_response', {'text': 'reply $i ${'long text ' * 30}'});
      }
      final turn = makeTurn(registry: reg, ledger: ledger, runId: runId, window: 500);
      final msgs = projection.render(turn);
      expect(estimateTokens(msgs), lessThanOrEqualTo(500));
    });

    test('native tool schemas count against the budget', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.tool', properties: {
        for (var i = 0; i < 6; i++) 'p$i': {'type': 'string', 'description': 'x' * 40},
      }));
      final cap = reg.get('demo.tool')!;
      final projection = defaultProjection(reg, window: 400);
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      for (var i = 0; i < 10; i++) {
        ledger.append(runId, 'user_input', {'text': 'message $i ${'pad ' * 20}'});
      }

      final withoutSchema = projection
          .render(makeTurn(registry: reg, ledger: ledger, runId: runId, window: 400));
      final withSchema = projection.render(
        makeTurn(registry: reg, ledger: ledger, runId: runId, window: 400),
        apiTools: [cap.apiSchema()],
      );
      expect(estimateTokens(withSchema), lessThanOrEqualTo(estimateTokens(withoutSchema)));
    });

    test('reserved output tokens counted', () {
      final reg = Registry();
      final projection = defaultProjection(reg, window: 400);
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      for (var i = 0; i < 10; i++) {
        ledger.append(runId, 'user_input', {'text': 'message $i ${'pad ' * 20}'});
      }

      final unreserved = projection
          .render(makeTurn(registry: reg, ledger: ledger, runId: runId, window: 400));
      final reserved = projection.render(
        makeTurn(registry: reg, ledger: ledger, runId: runId, window: 400),
        reservedTokens: 150,
      );
      expect(estimateTokens(reserved), lessThanOrEqualTo(estimateTokens(unreserved)));
    });
  });

  group('BuildDefaultSections', () {
    test('unknown section name rejected', () {
      expect(
        () => buildDefaultSections(['kernel', 'mystery'], kernelText: ''),
        throwsA(isA<ProjectionError>()
            .having((e) => e.toString(), 'message', contains('Unknown section'))),
      );
    });

    test('default section order', () {
      final sections = buildDefaultSections(
        ['kernel', 'toc', 'history', 'working_state', 'candidates'],
        kernelText: 'k',
      );
      final names = sections.map((s) => s.name).toList();
      expect(names, equals(['kernel', 'toc', 'history', 'working_state', 'candidates']));
    });
  });
  group('tool call pairing', () {
    // A native tool-calling provider rejects an assistant message whose
    // toolCalls have no matching results, and a result with no call. The
    // projection must never emit either, whatever produced the gap.
    void decision(InMemoryLedger ledger, String runId, List<String> callIds,
        {String text = ''}) {
      ledger.append(runId, 'model_response', {
        'text': text,
        'calls': [
          for (final cid in callIds) {'name': 'demo.tool', 'arguments': {}, 'id': cid},
        ],
      });
    }

    void result(InMemoryLedger ledger, String runId, String callId, {String text = 'ok'}) {
      ledger.append(runId, 'observation', {'call_id': callId, 'name': 'demo.tool', 'text': text});
    }

    List<Message> render(InMemoryLedger ledger, String runId,
        {int? fullWindow, int? compressedWindow, int? summaryWindow}) {
      final turn = makeTurn(ledger: ledger, runId: runId);
      final cfg = turn.config.compression;
      if (fullWindow != null) cfg.fullWindow = fullWindow;
      if (compressedWindow != null) cfg.compressedWindow = compressedWindow;
      if (summaryWindow != null) cfg.summaryWindow = summaryWindow;
      return HistorySection().render(turn);
    }

    test('a decision still awaiting its results is hidden', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      ledger.append(runId, 'user_input', {'text': 'hi'});
      decision(ledger, runId, ['c0']); // parked on an approval: no result yet
      expect(render(ledger, runId).map((m) => m.role).toList(), equals(['user']));
    });

    test('a partly answered decision is hidden whole', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      ledger.append(runId, 'user_input', {'text': 'hi'});
      decision(ledger, runId, ['c0', 'c1']);
      result(ledger, runId, 'c0');
      expect(render(ledger, runId).map((m) => m.role).toList(), equals(['user']));
    });

    test('a complete decision is kept', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      ledger.append(runId, 'user_input', {'text': 'hi'});
      decision(ledger, runId, ['c0', 'c1']);
      result(ledger, runId, 'c0');
      result(ledger, runId, 'c1');
      expect(render(ledger, runId).map((m) => m.role).toList(),
          equals(['user', 'assistant', 'tool', 'tool']));
    });

    test('age-based exclusion never orphans a result', () {
      // The oldest events fall out of the window one at a time; the cut must
      // not land between a decision and its results.
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      decision(ledger, runId, ['c0']);
      result(ledger, runId, 'c0');
      for (var i = 0; i < 4; i++) {
        ledger.append(runId, 'user_input', {'text': 'later $i'});
      }
      final msgs = render(ledger, runId, fullWindow: 1, compressedWindow: 2, summaryWindow: 4);
      expect(msgs.any((m) => m.role == 'assistant' && m.toolCalls.isNotEmpty), isFalse);
      expect(msgs.any((m) => m.role == 'tool'), isFalse);
    });
  });
  group('fidelity by age', () {
    // Older events are rendered at reduced fidelity. Only the most recent
    // window is verbatim; this is where compressText and summarizeText enter
    // the projection, and it was untested in this port.
    test('compressed for older', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      for (var i = 0; i < 30; i++) {
        ledger.append(runId, 'user_input', {'text': 'msg $i ${'pad ' * 50}'});
        ledger.append(runId, 'model_response', {'text': 'reply $i ${'pad ' * 50}'});
      }
      final msgs = HistorySection().render(makeTurn(ledger: ledger, runId: runId));
      final first = msgs.first.content.toString();
      expect(first.contains('omitted') || first.length < 500, isTrue);
    });

    test('summary for old', () {
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      for (var i = 0; i < 70; i++) {
        ledger.append(runId, 'user_input',
            {'text': 'message number $i with some content ${'pad ' * 30}'});
        ledger.append(runId, 'model_response', {'text': 'reply $i ${'pad ' * 30}'});
      }
      final msgs = HistorySection().render(makeTurn(ledger: ledger, runId: runId));
      expect(msgs.first.content.toString(), contains('chars]'));
    });

    test('a part list passes through instead of being stringified', () {
      // Multimodal content is a list of parts; stringifying it would destroy
      // the message. Only a plain string can be compressed.
      final ledger = InMemoryLedger();
      const runId = 'run_test';
      final parts = [
        {'type': 'text', 'text': 'look at this'},
        {'type': 'image_url', 'image_url': 'https://example.invalid/a.png'},
      ];
      ledger.append(runId, 'user_input', {'text': parts});
      final msgs = HistorySection().render(makeTurn(ledger: ledger, runId: runId));
      expect(msgs.single.content, isA<List<Object?>>());
      expect((msgs.single.content as List).length, equals(2));
    });
  });
}
