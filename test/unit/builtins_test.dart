// Bundled packs: installation rules and handler contracts.
//
// Port of `tests/unit/test_builtins.py`.
import 'dart:async';
import 'dart:io';

import 'package:state_projection_loop/src/builtin/builtin.dart' show install;
import 'package:state_projection_loop/src/builtin/meta.dart' show childSession;
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
          'tasks': [
            {
              'task': 't',
              'checklist_ids': [id, id, 'missing'],
            }
          ],
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test("a child is an ordinary run in the parent's ledger", () async {
      // The child used to get a throwaway InMemoryLedger, so sub-agent work
      // was absent from the one thing the package calls the truth.
      final session =
          _parent((model) => ScriptedLLM([DecisionStep(ScriptedLLM.finish('from the child'))]));
      final entry = ((await session.invoke('meta.agent.spawn', {
        'tasks': [
          {'task': 'work'}
        ]
      }) as List)
          .single) as Map;

      expect(entry['state'], 'COMPLETED');
      expect(entry['result'], 'from the child');
      final spawned = [
        for (final e in session.ledger.iterRun(session.run.id))
          if (e.type == 'run_spawned') ...(e.data['child_run_ids'] as List),
      ];
      expect(spawned, [entry['run_id']]);
      expect([for (final e in session.ledger.iterRun(entry['run_id'] as String)) e.type],
          contains('model_response'));
      expect([for (final r in session.ledger.listRuns()) r.runId], contains(entry['run_id']));
    });

    test('tasks in one call run concurrently', () async {
      // Each child's first step waits for the other's; serial execution
      // would deadlock, so only real concurrency gets past the timeout.
      final arrived = [Completer<void>(), Completer<void>()];
      var next = 0;
      final session = _parent((model) => _Rendezvous(next++, arrived));
      final entries = await session.invoke('meta.agent.spawn', {
        'tasks': [
          {'task': 'a'},
          {'task': 'b'}
        ]
      }) as List;
      expect([for (final e in entries) (e as Map)['result']], ['child 0', 'child 1']);
    });

    for (final (decision, ran) in [('approved', true), ('denied', false)]) {
      test("a child's approval is resolved on the root session ($decision)", () async {
        // A child that stopped for approval used to be returned as the
        // parent's tool result and then dropped on the floor: unapprovable,
        // unresumable, invisible.
        final done = <String>[];
        final session = _parentWithGuardedTool(done);
        final pending = await session.invoke('meta.agent.spawn', {
          'tasks': [
            {'task': 'work'}
          ]
        }) as ApprovalRequest;

        expect(session.run.state, 'WAITING_FOR_APPROVAL');
        expect(pending.reason, startsWith('sub-agent run_'));
        expect([for (final e in pending.effects) e.resource], ['guarded']);

        session.resolveApproval(decision);
        expect(await session.resume(), 'parent done');
        expect(done, ran ? ['x'] : isEmpty);
        expect(_childState(session), ['COMPLETED', ran ? 'did it' : 'blocked']);
      });
    }

    test('a parked child survives a restart', () async {
      final dir = Directory.systemTemp.createTempSync('spal_spawn');
      try {
        final config = Config.fromDict({
          'persistence': {'ledger_directory': dir.path}
        });
        final done = <String>[];
        var session = _parentWithGuardedTool(done, config: config);
        await session.invoke('meta.agent.spawn', {
          'tasks': [
            {'task': 'work'}
          ]
        });
        final runId = session.run.id;

        session = _parentWithGuardedTool(done, config: config, resume: runId);
        expect(session.run.state, 'WAITING_FOR_APPROVAL');
        session.resolveApproval('approved');
        expect(await session.resume(), 'parent done');
        expect(done, ['x']);
        expect(_childState(session), ['COMPLETED', 'did it']);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('interrupt reaches a running child', () async {
      late Session session;
      session = _parent((model) => ScriptedLLM([
            CallbackStep((messages, tools) {
              session.interrupt();
              return ScriptedLLM.call('meta.tool.find', arguments: {'query': 'anything'});
            }),
            DecisionStep(ScriptedLLM.finish('never')),
          ]));
      final entry = ((await session.invoke('meta.agent.spawn', {
        'tasks': [
          {'task': 'work'}
        ]
      }) as List)
          .single) as Map;
      expect(entry['state'], 'CANCELLED');
      expect(entry['result'], isNull);
    });

    test('budget is split between children and charged back', () async {
      var next = 0;
      // Three: the childSession() probe below takes one from the factory too.
      final scripts = [
        for (var i = 0; i < 3; i++) ScriptedLLM([DecisionStep(ScriptedLLM.finish('done'))]),
      ];
      final session = _parent((model) => scripts[next++],
          config: Config.fromDict({
            'budget': {'max_tokens': 1000}
          }));
      session.budget.promptTokens = 200;
      // Each child gets a slice of what is LEFT, not a fresh full limit.
      expect(childSession(session, {'task': 'a'}, 2).config.budget.maxTokens, 400);

      await session.invoke('meta.agent.spawn', {
        'tasks': [
          {'task': 'a'},
          {'task': 'b'}
        ]
      });
      expect(session.budget.promptTokens, greaterThan(200)); // the children's usage came home
    });

    test('a child cannot ask the user', () async {
      final tools = <List<Object?>>[];
      final session = _parent(
          (model) => ScriptedLLM([
                CallbackStep((messages, apiTools) {
                  tools.add([for (final t in apiTools ?? const []) (t as Map)['name']]);
                  return ScriptedLLM.finish('done');
                }),
              ]),
          builtins: const ['meta', 'spawn', 'ask']);
      await session.invoke('meta.agent.spawn', {
        'tasks': [
          {
            'task': 'work',
            'tool_scope': ['*']
          }
        ]
      });
      expect(tools.single, isNot(contains('meta__user__ask')));
    });
  });
}

/// A model adapter that will not answer until its sibling has also been
/// asked. Serial execution can never get past this.
class _Rendezvous implements LLMAdapter {
  _Rendezvous(this.i, this.arrived);

  final int i;
  final List<Completer<void>> arrived;

  @override
  Future<Decision> complete(List<Message> messages,
      [List<Map<String, Object?>>? tools, void Function(String)? onDelta]) async {
    if (!arrived[i].isCompleted) arrived[i].complete();
    await arrived[1 - i].future.timeout(const Duration(seconds: 2));
    return ScriptedLLM.finish('child $i');
  }
}

Session _parent(LLMAdapter Function(String?)? children,
    {Config? config, List<String> builtins = const ['meta', 'spawn']}) {
  return Session(
    ScriptedLLM([]),
    policy: allowAll(),
    builtins: builtins,
    config: config,
    spawnLlmFactory: children,
  );
}

/// The sub-agent's own run, read back out of the ledger the way an audit
/// would: terminal state and result, from its snapshot.
List<Object?> _childState(Session session) {
  String? runId;
  for (final e in session.ledger.iterRun(session.run.id)) {
    if (e.type == 'run_spawned') runId = (e.data['child_run_ids'] as List).first as String;
  }
  final snapshot = session.ledger.loadSnapshot(runId!)!;
  return [snapshot.state['state'], snapshot.state['result']];
}

/// A parent whose child calls one capability the policy holds for approval,
/// then finishes with whatever it was told.
Session _parentWithGuardedTool(List<String> done, {Config? config, String? resume}) {
  final registry = Registry();
  registry.register(
    capabilityDict('demo.guarded.write',
        category: 'demo',
        properties: {
          'text': {'type': 'string'}
        },
        effects: [('write', 'guarded')]),
    handler: (args) {
      done.add(args['text'] as String);
      return 'written';
    },
  );
  final policy = PolicyEngine(defaultDecision: 'allow');
  policy.addRule('developer',
      Rule(decision: 'require_approval', capabilityPattern: 'demo.guarded.write', reason: 'needs a human'));

  // Content-driven, not positional: a reattached child is handed a fresh
  // adapter, exactly as a real one would be.
  LLMAdapter childLlm(String? model) => ScriptedLLM([
        for (var i = 0; i < 4; i++)
          CallbackStep((messages, tools) {
            final seen = [for (final m in messages) '${m.content}'].join(' ');
            if (seen.contains('written')) return ScriptedLLM.finish('did it');
            if (seen.contains('denied')) return ScriptedLLM.finish('blocked');
            return ScriptedLLM.call('demo.guarded.write', arguments: {'text': 'x'});
          }),
      ]);

  if (resume != null) {
    return Session.resumeFromLedger(ScriptedLLM([const TextStep('parent done')]), resume,
        config: config, registry: registry, policy: policy,
        builtins: const ['meta', 'spawn'], spawnLlmFactory: childLlm);
  }
  return Session(ScriptedLLM([const TextStep('parent done')]),
      registry: registry,
      policy: policy,
      builtins: const ['meta', 'spawn'],
      spawnLlmFactory: childLlm,
      config: config);
}
