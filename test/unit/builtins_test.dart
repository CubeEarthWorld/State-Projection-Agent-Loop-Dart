// Bundled packs: installation rules and handler contracts.
//
// Port of `tests/unit/test_builtins.py`.
import 'package:state_projection_loop/src/builtin/builtin.dart' show install;
import 'package:state_projection_loop/src/builtin/state.dart' show stateHandlers;
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

ToolContext ctx() => ToolContext(config: Config(), registry: Registry());

void main() {
  group('Install', () {
    test('a disabled developer definition is not overwritten', () {
      // `get()` returns null for a disabled capability, so testing
      // membership with it made a switched-off name look unregistered and
      // the pack replaced it — losing the developer's definition.
      final reg = Registry();
      reg.register(capabilityDict('meta.tool.find', category: 'mine', description: 'Mine.'),
          handler: okHandlerFactory('mine'));
      reg.disable(['meta.tool.find']);
      installBuiltins(reg, ['meta']);
      reg.enable(['meta.tool.find']);
      expect(reg.get('meta.tool.find')!.category, equals('mine'));
      expect(reg.get('meta.tool.find')!.spec.description, equals('Mine.'));
    });

    test('an enabled developer definition still wins', () {
      final reg = Registry();
      reg.register(capabilityDict('meta.tool.find', category: 'mine'),
          handler: okHandlerFactory('mine'));
      installBuiltins(reg, ['meta']);
      expect(reg.get('meta.tool.find')!.category, equals('mine'));
    });

    test('a definition without a handler fails at install', () {
      // Adding a tool to a shared <pack>.json with no handler must not
      // register a capability that only fails when the model calls it.
      final reg = Registry();
      expect(() => install(reg, [capabilityDict('demo.no.handler')], {}),
          throwsA(isA<ArgumentError>()));
      expect(reg.hasDefinition('demo.no.handler'), isFalse);
    });
  });

  group('StateHandlers', () {
    test('extra.get reports a missing key but throws on an empty path', () {
      // The schema allows `path: ""`; only the missing-key case is an
      // answer, an unusable path is an error.
      final c = ctx();
      expect(stateHandlers['state.extra.get']!(c, {'path': 'nope'}), equals('(not set: nope)'));
      expect(() => stateHandlers['state.extra.get']!(c, {'path': ''}),
          throwsA(isA<ArgumentError>()));
    });

    test('next_actions echoes a quoted list', () {
      expect(
        stateHandlers['state.next_actions.set']!(ctx(), {
          'actions': ['a', 'b']
        }),
        equals("next_actions set: ['a', 'b']"),
      );
    });

    test('append handlers stay unique', () {
      final cases = {
        'state.fact.add': (WorkingState ws) => ws.confirmedFacts,
        'state.constraint.add': (WorkingState ws) => ws.constraints,
        'state.question.add': (WorkingState ws) => ws.openQuestions,
      };
      for (final entry in cases.entries) {
        final c = ctx();
        stateHandlers[entry.key]!(c, {'text': 'x'});
        stateHandlers[entry.key]!(c, {'text': 'x'});
        expect(entry.value(c.workingState), equals(['x']), reason: entry.key);
      }
    });
  });

  group('Spawn', () {
    test('duplicate checklist ids are rejected before any work', () async {
      final session = Session(ScriptedLLM([const TextStep('done')]),
          policy: allowAll(), builtins: const ['meta', 'spawn']);
      session.checklists.execute('create', {
        'name': 'a',
        'items': [
          {'text': 'one'}
        ],
      });
      final id = ((session.checklists.toDict()['checklists'] as List).first
          as Map)['id'] as String;
      final handler = session.registry.get('meta.agent.spawn')!.execution.handler!;
      await expectLater(
        () async => await handler(
            ToolContext(config: session.config, registry: session.registry, session: session), {
          'task': 't',
          'checklist_ids': [id, id, 'missing'],
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
