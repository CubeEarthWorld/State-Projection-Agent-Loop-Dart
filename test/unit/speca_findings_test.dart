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
}
