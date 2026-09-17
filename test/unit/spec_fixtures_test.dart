// The cross-language contract.
//
// These fixtures are read by both packages' test suites. A change here that
// is not mirrored in the other language is exactly the kind of silent drift
// that produced two different content hashes, two different glob dialects
// and two different truncation rules — each of which only showed up in
// production. They are generated from the Python implementation; see
// spec/README.md.
import 'dart:convert';
import 'dart:io';

import 'package:state_projection_loop/src/builtin/builtin.dart';
import 'package:state_projection_loop/src/builtin/defs.g.dart' as defs;
import 'package:state_projection_loop/src/capability.dart';
import 'package:state_projection_loop/src/config.dart';
import 'package:state_projection_loop/src/llm.dart';
import 'package:state_projection_loop/src/messages.dart';
import 'package:state_projection_loop/src/session.dart';
import 'package:state_projection_loop/src/registry.dart';
import 'package:state_projection_loop/src/compression.dart';
import 'package:state_projection_loop/src/json_schema.dart';
import 'package:state_projection_loop/src/policy.dart';
import 'package:state_projection_loop/src/serialization.dart';
import 'package:state_projection_loop/src/tokens.dart';
import 'package:test/test.dart';

Map<String, Object?> load(String name) => (jsonDecode(
      File('spec/fixtures/$name.json').readAsStringSync(),
    ) as Map).cast<String, Object?>();

List<Map<String, Object?>> cases(String name, String key) =>
    [for (final c in load(name)[key] as List) (c as Map).cast<String, Object?>()];

void main() {
  group('compression fixtures', () {
    for (final c in cases('compression', 'content_hash')) {
      test('contentHash ${jsonEncode(c['text'])}', () {
        expect(contentHash(c['text'] as String), equals(c['expected']));
      });
    }
    for (final c in cases('compression', 'strip_noise')) {
      test('stripNoise ${jsonEncode(c['text'])}', () {
        expect(stripNoise(c['text'] as String), equals(c['expected']));
      });
    }
    for (final c in cases('compression', 'summarize_text')) {
      test('summarizeText ${jsonEncode(c['text'])}', () {
        expect(summarizeText(c['text'] as String), equals(c['expected']));
      });
    }
    for (final c in cases('compression', 'head_tail_truncate')) {
      test('headTailTruncate ${jsonEncode(c['text'])} @${c['max_lines']}', () {
        expect(headTailTruncate(c['text'] as String, (c['max_lines'] as num).toInt()),
            equals(c['expected']));
      });
    }
  });

  group('policy glob fixtures', () {
    for (final c in cases('policy_glob', 'glob_match')) {
      test('globMatch ${jsonEncode(c['value'])} ~ ${jsonEncode(c['pattern'])}', () {
        expect(globMatch(c['value'] as String, c['pattern'] as String), equals(c['expected']));
      });
    }
  });

  group('capability fixtures', () {
    for (final c in cases('capability', 'synthesize_signature')) {
      test('synthesizeSignature ${c['name']}', () {
        expect(
          synthesizeSignature(
              c['name'] as String, (c['parameters'] as Map).cast<String, Object?>()),
          equals(c['expected']),
        );
      });
    }
    for (final c in cases('capability', 'api_name')) {
      test('toApiName ${c['name']}', () {
        expect(toApiName(c['name'] as String), equals(c['expected']));
      });
    }
  });

  group('serialization fixtures', () {
    for (final c in cases('serialization', 'dumps')) {
      test('dumps ${jsonEncode(c['value'])}', () {
        expect(dumps(c['value']), equals(c['expected']));
      });
    }
    for (final c in cases('serialization', 'estimate_tokens')) {
      test('estimateTokens ${jsonEncode(c['value'])}', () {
        expect(estimateTokens(c['value']), equals(c['expected']));
      });
    }
  });
  test('projection matches the golden turn', () async {
    // The same scenario as projection_scenario() in the Python package's
    // spec/generate_fixtures.py: one whole turn as the model receives it.
    Map<String, Object?> cap(String name, String description, Map<String, Object?> parameters,
            {String category = 'demo', Map<String, Object?> discovery = const {}}) =>
        {
          'name': name,
          'category': category,
          'spec': {'description': description, 'parameters': parameters},
          'discovery': discovery,
          'effects': [
            {'kind': 'read', 'resource': 'workspace:*'},
          ],
        };
    final warehouse = {
      'type': 'object',
      'properties': {
        'warehouse': {'type': 'string'},
      },
      'required': ['warehouse'],
    };
    final registry = Registry();
    registry.register(
        cap('demo.echo.say', 'Echo the text back. Useful for tests.', {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'default': 'hi'},
          },
        }, discovery: {
          'pinned': true,
          'kernel_note': 'Use demo.echo.say to repeat text.',
        }),
        handler: (args) => 'echo: ${args['text']}');
    registry.register(
        cap('inventory.stock.get', '在庫数を返す。Returns the stock count.', warehouse,
            category: 'inventory', discovery: {'embedding_text': '在庫 stock warehouse inventory'}),
        handler: (args) => {'warehouse': args['warehouse'], 'stock': 42});
    registry.register(
        cap('inventory.stock.audit', 'Audit the stock of a warehouse.', warehouse,
            category: 'inventory', discovery: {'require_spec': true}),
        handler: (args) => 'audited');
    final llm = ScriptedLLM([
      DecisionStep(Decision(text: 'checking', calls: [
        ToolCall(name: 'inventory.stock.get', arguments: {'warehouse': 'tokyo'}, id: 'c1'),
        ToolCall(name: 'inventory.stock.audit', arguments: {'warehouse': 7}, id: 'c2'),
      ])),
      DecisionStep(ScriptedLLM.finish('42')),
    ]);
    final session = Session(llm,
        kernel: 'You are a stock agent.',
        registry: registry,
        config: Config.fromDict({'mode': 'job'}),
        policy: PolicyEngine(defaultDecision: 'allow'),
        seed: {
          'goal': 'report tokyo stock',
          'confirmed_facts': ['tokyo is a warehouse'],
          'decisions': [
            {'text': 'use inventory tools', 'reason': 'they are authoritative'},
          ],
          'flags': {'urgent': true},
        });
    await session.runJob('How much stock does the tokyo warehouse have?');
    final request = llm.requests.last;
    final actual = {
      'messages': [
        for (final m in request['messages'] as List<Message>)
          {
            'role': m.role,
            'content': m.content,
            'tool_call_id': m.toolCallId,
            'name': m.name,
            'tool_calls': [
              for (final c in m.toolCalls) {'id': c.id, 'name': c.name, 'arguments': c.arguments},
            ],
          },
      ],
      'tools': request['tools'],
    };
    expect(jsonDecode(jsonEncode(actual)), equals(load('projection')));
  });

  group('bundled tool definitions', () {
    // The definitions are data shared with the Python package. They are
    // embedded as a generated constant because Dart cannot portably read a
    // package's own data files at runtime — so the constant must stay in
    // step with the JSON it was generated from.
    for (final name in ['meta', 'spawn', 'state', 'checklist']) {
      test('$name matches spec/tools/$name.json', () {
        final onDisk = jsonDecode(File('spec/tools/$name.json').readAsStringSync());
        expect(jsonEncode(defs.load(name)), equals(jsonEncode(onDisk)),
            reason: 'run: dart run tool/generate_defs.dart');
      });
    }

    test('every definition has a handler', () {
      final registry = Registry();
      installBuiltins(registry, ['meta', 'checklist', 'spawn', 'state']);
      expect(registry.all(), isNotEmpty);
      for (final capability in registry.all()) {
        expect(capability.execution.handler, isNotNull,
            reason: '${capability.name} would fail at call time with no_handler');
      }
    });
  });
  group('validation fixtures', () {
    // Validation messages are a self-repair prompt sent to the model, so the
    // wording is part of the contract, not an implementation detail.
    for (final c in cases('validation', 'validate_args')) {
      test('validateArgs ${jsonEncode(c['arguments'])}', () {
        expect(
          validateArgs((c['schema'] as Map).cast<String, Object?>(), c['arguments']),
          equals(c['expected']),
        );
      });
    }
    for (final c in cases('validation', 'apply_defaults')) {
      test('applyDefaults ${jsonEncode(c['arguments'])}', () {
        expect(
          jsonEncode(applyDefaults((c['schema'] as Map).cast<String, Object?>(),
              (c['arguments'] as Map).cast<String, Object?>())),
          equals(jsonEncode(c['expected'])),
        );
      });
    }
  });
}
