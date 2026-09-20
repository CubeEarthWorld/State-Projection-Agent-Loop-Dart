// Defects the speca spec-driven audit surfaced against the Python
// reference, then confirmed here. The mirror lives at
// `tests/unit/test_regressions.py::TestSpecaFindings`.
//
// The RecursionError one is Python-only: Dart's jsonDecode returns without
// throwing on the same deeply nested input.
import 'dart:io';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:state_projection_loop/src/compression.dart';
import 'package:test/test.dart';

void main() {
  test('a line torn mid-character does not break resume', () {
    final dir = Directory.systemTemp.createTempSync('spal_torn');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ledger = JsonlLedger(dir.path);
    ledger.append('run_1', 'user_input', {'text': 'hello'});
    ledger.append('run_1', 'user_input', {'text': 'こんにちは世界'});
    final file = File('${dir.path}/run_1.jsonl');
    // A crash mid-append can truncate inside a multi-byte character, so the
    // bytes do not decode at all — the JSON guard never even sees the line.
    final raw = file.readAsBytesSync();
    file.writeAsBytesSync(raw.sublist(0, raw.length - 12));
    expect(ledger.iterRun('run_1').length, equals(1));
  });

  test('a number inside a longer number does not ground it', () {
    expect(ungrounded('order 942 was cancelled', 'we looked at commit 8942'),
        equals(['942']));
    expect(ungrounded('v1.2 shipped', 'we tagged v1.23 last week'),
        equals(['v1.2']));
    // Punctuation is still a boundary, so a real path stays grounded.
    expect(ungrounded('see src/main.py', 'edited a/src/main.py:42 today'),
        isEmpty);
  });

  test('identical calls in one batch hit the repeat cap', () async {
    final ran = <String>[];
    final registry = Registry();
    registry.register({
      'name': 'demo.read.thing',
      'category': 'demo',
      'spec': {
        'description': 'Read a thing.',
        'parameters': {
          'type': 'object',
          'properties': {'x': {'type': 'string'}},
          'required': ['x'],
        },
      },
      'effects': [{'kind': 'read', 'resource': 'workspace:*'}],
    }, handler: (Map<String, Object?> args) {
      ran.add(args['x'] as String);
      return 'ok';
    });
    final config = Config();

    Future<int> run(String Function(int) argument) async {
      ran.clear();
      final llm = ScriptedLLM([
        DecisionStep(Decision(text: 'go', calls: [
          for (var i = 0; i < 8; i++)
            ToolCall(name: 'demo.read.thing', arguments: {'x': argument(i)}, id: 'c$i'),
        ])),
        DecisionStep(ScriptedLLM.finish('done')),
      ]);
      await Session(llm,
              kernel: 'k',
              registry: registry,
              config: config,
              policy: PolicyEngine(defaultDecision: 'allow'))
          .runJob('go');
      return ran.length;
    }

    // Read-only calls are buffered and run concurrently, so the
    // result-keyed loop guard could never see them repeat.
    expect(await run((_) => 'same'), equals(config.limits.maxRepeats));
    expect(await run((i) => 'v$i'), equals(8));
  });

  test('an undeclared effect still counts as irreversible', () {
    final registry = Registry();
    // No effects at all. Policy and the runtime already treat that as
    // external; the rewind/branch notice used to read the raw list and
    // report it as safe.
    registry.register({
      'name': 'demo.send.thing',
      'category': 'demo',
      'spec': {'description': 'Send a thing.'},
    }, handler: (Map<String, Object?> _) => 'sent');
    final capability = registry.get('demo.send.thing')!;
    expect(capability.effects, isEmpty);
    expect(capability.plannedEffects.any((e) => e.kind == 'external'), isTrue);
  });

  test('an oversized items array is rejected on length', () {
    final registry = Registry();
    installBuiltins(registry, ['checklist']);
    final parameters = registry.get('planning.checklist.manage')!.spec.parameters;
    final watch = Stopwatch()..start();
    final error = validateArgs(parameters, {
      'action': 'create',
      'name': 'x',
      'items': [for (var i = 0; i < 200000; i++) {'text': 'i$i'}],
    });
    watch.stop();
    // Without maxItems the validator walked every entry before the
    // handler's own 200 cap could reject it, on the shared event loop.
    expect(error, contains('maxItems'));
    expect(watch.elapsedMilliseconds, lessThan(1000));
    expect(
        validateArgs(parameters, {
          'action': 'create',
          'name': 'x',
          'items': [for (var i = 0; i < 200; i++) {'text': 'i$i'}],
        }),
        isNull);
  });

  test('shrinking history never drops a user message', () {
    final section = HistorySection();
    final current = [
      Message(role: kUser, content: 'the original instruction'),
      Message(role: kAssistant, content: 'working on it'),
      Message(role: kObservation, content: 'tool said so', toolCallId: 'c1'),
      Message(role: kUser, content: 'a later turn'),
    ];
    final ctx = TurnContext(config: Config(), registry: Registry());
    final shrunk = section.shrink(ctx, current)!;
    // The assistant turn and the observation answering it go first; both
    // user turns survive, including the original instruction.
    expect(shrunk.map((m) => m.role), equals([kUser, kUser]));
    // Only user turns left: the window is a hard limit, so the oldest one
    // does finally go rather than the render overflowing.
    expect(section.shrink(ctx, shrunk)!.map((m) => m.role), equals([kUser]));
  });
}
