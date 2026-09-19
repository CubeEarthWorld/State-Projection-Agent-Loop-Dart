// The model call and what surrounds it: streaming deltas, the timeout /
// retry / fallback envelope, cancellation, hooks around tool calls, and
// content parts in the user message.
import 'dart:async';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

List<Map<String, Object?>> events(Session session, String kind) =>
    [for (final e in session.ledger.iterRun(session.run.id)) if (e.type == kind) e.data];

class _Plain implements LLMAdapter {
  @override
  Future<Decision> complete(List<Message> messages,
          [List<Map<String, Object?>>? tools, void Function(String)? onDelta]) async =>
      Decision(text: 'ok');
}

class _Hanging implements LLMAdapter {
  _Hanging({this.onStart});
  final void Function()? onStart;

  @override
  Future<Decision> complete(List<Message> messages,
      [List<Map<String, Object?>>? tools, void Function(String)? onDelta]) async {
    onStart?.call();
    await Future<void>.delayed(const Duration(seconds: 10));
    return Decision(text: 'late');
  }
}

class _Flaky implements LLMAdapter {
  var attempts = 0;

  @override
  Future<Decision> complete(List<Message> messages,
      [List<Map<String, Object?>>? tools, void Function(String)? onDelta]) async {
    attempts += 1;
    if (attempts == 1) throw StateError('429');
    return Decision(text: 'fine');
  }
}

class _Broken implements LLMAdapter {
  @override
  Future<Decision> complete(List<Message> messages,
          [List<Map<String, Object?>>? tools, void Function(String)? onDelta]) async =>
      throw StateError('down');
}

Registry writeRegistry(List<String> seen) {
  final registry = Registry();
  registry.register(
      capabilityDict('demo.write',
          properties: {'path': {'type': 'string'}}, required: ['path'], effects: [('write', 'workspace:*')]),
      handler: (args) {
    seen.add(args['path'] as String);
    return 'wrote ${args['path']}';
  });
  return registry;
}

void main() {
  group('streaming', () {
    test('model text and tool progress reach onDelta but not the ledger', () async {
      final registry = Registry();
      registry.register(capabilityDict('demo.slow.work'), handler: (ToolContext ctx, Map<String, Object?> args) {
        ctx.emit('50%');
        return 'done';
      }, wantsCtx: true);
      final deltas = <(String, String)>[];
      final session = Session(
        ScriptedLLM([DecisionStep(ScriptedLLM.call('demo.slow.work')), const TextStep('all done')]),
        registry: registry,
        policy: allowAll(),
        onDelta: (source, text) => deltas.add((source, text)),
      );
      expect(await session.send('go'), 'all done');
      expect(deltas, [('tool', '50%'), ('model', 'all done')]);
      expect(session.ledger.iterRun(session.run.id).map((e) => e.data.toString()).join(), isNot(contains('50%')));
    });

    test('an adapter that ignores onDelta still works', () async {
      expect(await Session(_Plain()).send('hi'), 'ok');
    });
  });

  group('model call envelope', () {
    test('a timeout is retried then recorded and thrown', () async {
      final session = Session(_Hanging(),
          config: Config.fromDict({
            'mode': 'job',
            'model': {'timeout_s': 0.01, 'retries': 2, 'backoff_s': 0},
          }));
      await expectLater(session.runJob('task'), throwsA(isA<TimeoutException>()));
      expect([for (final e in events(session, 'model_call_failed')) e['attempt']], [1, 2, 3]);
      expect(session.run.state, 'FAILED');
    });

    test('a provider error that clears up on retry is invisible to the caller', () async {
      final session = Session(_Flaky(), config: Config.fromDict({'model': {'retries': 1, 'backoff_s': 0}}));
      expect(await session.send('hi'), 'fine');
      expect([for (final e in events(session, 'model_call_failed')) e['error']], ['StateError: Bad state: 429']);
    });

    test('fallback adapter moves on when the first throws', () async {
      final session = Session(FallbackAdapter([_Broken(), ScriptedLLM([const TextStep('from the backup')])]));
      expect(await session.send('hi'), 'from the backup');
    });

    test('interrupt abandons a model call that is still waiting', () async {
      final started = Completer<void>();
      final session = Session(_Hanging(onStart: started.complete));
      final turn = session.send('go');
      await started.future;
      session.interrupt();
      expect(await turn.timeout(const Duration(seconds: 2)), '[interrupted]');
      expect(events(session, 'run_state_changed').last['reason'], 'interrupted');
    });
  });

  group('hooks', () {
    test('beforeCall may rewrite arguments and the rewrite is validated', () async {
      final seen = <String>[];
      final session = Session(
        ScriptedLLM([DecisionStep(ScriptedLLM.call('demo.write', arguments: {'path': 'a.txt'})), const TextStep('ok')]),
        registry: writeRegistry(seen),
        policy: allowAll(),
        hooks: Hooks(beforeCall: (cap, args, ctx) => {'path': 'sandbox/${args['path']}'}),
      );
      await session.send('go');
      expect(seen, ['sandbox/a.txt']);
      final intervened = events(session, 'hook_intervened').single;
      expect(intervened['stage'], 'before');
      expect(intervened['arguments'], {'path': 'sandbox/a.txt'});
      expect(intervened['command_id'], session.run.commands.keys.single);
    });

    test('beforeCall may reject, and an invalid rewrite is a rejection', () async {
      final seen = <String>[];
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.calls([('demo.write', {'path': 'a.txt'}), ('demo.write', {'path': 'b'})])),
          const TextStep('ok'),
        ]),
        registry: writeRegistry(seen),
        policy: allowAll(),
        hooks: Hooks(beforeCall: (cap, args, ctx) => args['path'] == 'a.txt' ? 'lint failed' : {'path': 3}),
      );
      await session.send('go');
      expect(seen, isEmpty);
      final observations = [for (final e in events(session, 'observation')) e['text'] as String];
      expect(observations[0], 'Rejected by hook: lint failed');
      expect(observations[1], startsWith('Rejected by hook: hook returned invalid arguments'));
      expect([for (final c in session.run.commands.values) c.outcome], ['failed', 'failed']);
    });

    test('afterCall may replace the observation', () async {
      final seen = <String>[];
      final session = Session(
        ScriptedLLM([DecisionStep(ScriptedLLM.call('demo.write', arguments: {'path': 'a.txt'})), const TextStep('ok')]),
        registry: writeRegistry(seen),
        policy: allowAll(),
        hooks: Hooks(afterCall: (cap, args, result, ctx) => result.observation.replaceAll('a.txt', '[redacted]')),
      );
      await session.send('go');
      expect([for (final e in events(session, 'observation')) e['text']], ['wrote [redacted]']);
      expect(events(session, 'hook_intervened').single['stage'], 'after');
    });
  });

  group('content parts', () {
    test('a user message may carry image parts', () async {
      final parts = [
        {'type': 'text', 'text': 'what is this?'},
        {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,${'A' * 40000}'}},
      ];
      final llm = ScriptedLLM([const TextStep('a cat')]);
      final session = Session(llm);
      expect(await session.send(parts), 'a cat');
      final user = (llm.requests.first['messages'] as List<Message>).firstWhere((m) => m.role == 'user');
      expect(user.content, parts);
      expect(estimateTokens(parts[1]), imageTokens);
      expect(estimateTokens(user), lessThan(2 * imageTokens), reason: 'the base64 body must not be counted as text');
    });
  });
}
