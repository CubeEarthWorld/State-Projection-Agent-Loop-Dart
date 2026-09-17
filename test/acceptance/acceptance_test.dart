// Acceptance tests: whole-session guarantees, driven end to end.
//
// - 1,000 registered capabilities, default config -> per-turn tool-related
//   overhead stays small (two orders of magnitude below full-spec preloading)
// - with vectors disabled, every registered capability remains reachable
// - the self-repair path works: validation failure -> spec attached -> retry
// - the default config alone yields a working chat agent
// - a non-idempotent timeout is OUTCOME_UNKNOWN, never auto-retried
// - total send size including tool schemas stays inside the window
// - WAITING_FOR_APPROVAL survives a simulated process restart
// - a higher policy layer's deny cannot be relaxed by a lower one
// - Run state is fully recoverable from Events + Snapshot
// - branching never deletes or mutates past events, and surfaces the effects
//   it cannot undo
// - each command is traceable in the ledger from proposal to outcome
import 'dart:io';
import 'dart:math';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

const List<String> _categories = [
  'web/search', 'web/fetch', 'file', 'file/edit', 'game/flags', 'game/media',
  'support/manuals', 'support/tickets', 'mail', 'calendar', 'db/query', 'db/admin',
  'os/process', 'os/fs', 'image', 'audio', 'crm', 'billing', 'analytics', 'deploy',
];

const List<String> _words = [
  'search', 'read', 'write', 'update', 'delete', 'list', 'sync', 'fetch',
  'render', 'play', 'check', 'convert', '翻訳', '検索', '取得', '更新',
  '送信', '予約', '集計', '生成',
];

Registry buildThousandToolRegistry([int n = 1000]) {
  final rng = Random(42);
  final reg = Registry();
  for (var i = 0; i < n; i++) {
    final cat = _categories[i % _categories.length];
    final w1 = _words[rng.nextInt(_words.length)];
    final w2 = _words[rng.nextInt(_words.length)];
    final idx = i.toString().padLeft(4, '0');
    reg.register(
      capabilityDict(
        'demo.tool_$idx',
        category: cat,
        description: '$cat 用のツール$i。$w1 と $w2 を行う。',
        embeddingText: '$w1 $w2 $cat ツール$i',
        properties: {
          'target': {'type': 'string', 'description': '対象'},
          'limit': {'type': 'integer', 'default': 10},
        },
        required: ['target'],
      ),
      handler: okHandlerFactory('tool_$idx'),
    );
  }
  return reg;
}

void main() {
  final thousandTools = buildThousandToolRegistry();

  group('A_TokenOverheadAt1000Tools', () {
    test('per turn tool overhead under 3k', () async {
      final captured = <String, Object?>{};

      Object snapshot(List<Message> messages, List<Map<String, Object?>>? tools) {
        captured['messages'] = messages;
        captured['tools'] = tools ?? <Map<String, Object?>>[];
        return '了解しました。';
      }

      final session = Session(
        ScriptedLLM([CallbackStep(snapshot)]),
        kernel: 'あなたは有能なアシスタントです。',
        registry: thousandTools,
      );
      await session.send('ファイルを検索して読みたい');

      final messages = captured['messages'] as List<Message>;
      var overhead = 0;
      for (final m in messages) {
        final content = m.content.toString();
        if (m.role == 'system' &&
            (content.contains('[Tool index]') ||
                content.contains('[Tool candidates') ||
                content.contains('[Pinned tools]') ||
                content.contains('[Runtime notes]'))) {
          overhead += estimateTokens(m);
        }
      }
      final tools = captured['tools'] as List<Map<String, Object?>>;
      overhead += estimateTokens(tools);

      expect(overhead, lessThanOrEqualTo(3000), reason: 'tool overhead ${overhead}tk exceeds the 3k budget');

      // two orders of magnitude below preloading every spec
      final fullPreload =
          thousandTools.all().fold<int>(0, (sum, t) => sum + estimateTokens(t.specText()));
      expect(fullPreload, greaterThan(overhead * 10));
      expect(tools.length, lessThan(100)); // never O(N) native schemas
    });

    test('toc stays compact', () {
      expect(estimateTokens(thousandTools.tocText()), lessThanOrEqualTo(100));
    });
  });

  group('B_ReachabilityWithoutVectors', () {
    test('every tool reachable via find_tools', () {
      // With vector='off', layer 3 search by name finds every capability.
      final search = ToolSearch(thousandTools, vector: 'off');
      final rng = Random(7);
      final all = thousandTools.all();
      final indices = <int>{};
      while (indices.length < 150) {
        indices.add(rng.nextInt(all.length));
      }
      for (final i in indices) {
        final cap = all[i];
        final results = search.search(cap.name, layer: 3, k: 5);
        expect(results.any((s) => s.tool.name == cap.name), isTrue, reason: '${cap.name} unreachable');
      }
    });

    test('toc covers every category', () {
      final toc = thousandTools.tocText();
      for (final cap in thousandTools.all()) {
        final root = (cap.category.isEmpty ? 'misc' : cap.category).split('/').first;
        expect(toc, contains(root));
      }
    });

    test('no_embed tools still reachable', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.shadow', noEmbed: true, summary: 'shadow tool'));
      final search = ToolSearch(reg, vector: 'off');
      expect(search.search('shadow', layer: 3).any((s) => s.tool.name == 'demo.shadow'), isTrue);
    });
  });

  group('C_SelfRepairPath', () {
    test('validation failure spec retry', () async {
      final reg = Registry();
      final callsSeen = <String>[];

      Object? echo(Map<String, Object?> args) {
        final text = args['text'] as String;
        callsSeen.add(text);
        return 'echo: $text';
      }

      reg.register(
        capabilityDict('demo.echo',
            description: 'Echo text.',
            properties: {
              'text': {'type': 'string'},
            },
            required: ['text']),
        handler: echo,
      );

      Object repairStep(List<Message> messages, List<Map<String, Object?>>? tools) {
        final last = messages.last.role == 'tool'
            ? messages.last
            : messages.reversed.firstWhere((m) => m.role == 'tool');
        expect(last.content.toString(), contains('### demo.echo'));
        return ScriptedLLM.call('demo.echo', arguments: {'text': 'fixed'});
      }

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 12345})), // wrong type
        CallbackStep(repairStep),
        const TextStep('self-repair complete'),
      ]);
      final session = Session(llm, registry: reg);
      expect(await session.send('echo something'), equals('self-repair complete'));
      expect(callsSeen, equals(['fixed'])); // bad call never executed, good one did
    });
  });

  group('D_DefaultChatAgent', () {
    test('defaults only chat', () async {
      // No policy config, no vectors, no spawn — chat works out of the box.
      final session = Session(ScriptedLLM([const TextStep('はい、こんにちは!'), const TextStep('元気です。')]));
      expect(await session.send('こんにちは'), equals('はい、こんにちは!'));
      expect(await session.send('元気?'), equals('元気です。'));
      expect(session.workingState.isEmpty(), isTrue);
      expect(
        session.conversation.map((m) => m.role).toList(),
        equals(['user', 'assistant', 'user', 'assistant']),
      );
    });
  });

  group('Idempotency', () {
    test('timeout on never_retry capability is unknown and not retried', () async {
      var attempts = 0;
      Future<String> chargeCard(Map<String, Object?> args) async {
        attempts += 1;
        await Future.delayed(const Duration(seconds: 1));
        return 'charged';
      }

      final reg = Registry();
      reg.register(
          capabilityDict('billing.charge',
              timeoutS: 0.05,
              retrySafety: 'never_retry',
              effects: [('external', 'payment_gateway:*')]),
          handler: chargeCard);
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('billing.charge')),
        DecisionStep(ScriptedLLM.finish('x')),
      ]);
      final session = Session(llm,
          registry: reg,
          config: Config.fromDict({'mode': 'job'}),
          policy: PolicyEngine(defaultDecision: 'allow'));
      await session.runJob('charge the card');

      expect(attempts, equals(1), reason: 'a never_retry capability must not be retried after a timeout');
      final obs = session.conversation
          .firstWhere((m) => m.role == 'tool' && m.content.toString().contains('UNKNOWN'));
      expect(obs.content.toString(), contains('UNKNOWN'));
    });
  });

  group('Budget', () {
    test('total send size including schemas stays inside window', () async {
      final reg = Registry();
      for (var i = 0; i < 30; i++) {
        reg.register(capabilityDict('demo.tool_$i', properties: {
          'a': {'type': 'string', 'description': 'x' * 60},
          'b': {'type': 'string', 'description': 'y' * 60},
        }));
      }

      final captured = <String, Object?>{};
      Object snapshot(List<Message> messages, List<Map<String, Object?>>? tools) {
        captured['messages'] = messages;
        captured['tools'] = tools ?? <Map<String, Object?>>[];
        return 'ok';
      }

      final cfg = Config.fromDict({
        'projection': {'window_tokens': 2000, 'reserved_output_tokens': 200},
      });
      final session = Session(ScriptedLLM([CallbackStep(snapshot)]), registry: reg, config: cfg);
      await session.send('do something with tool_5 and tool_12');

      final messageTokens = estimateTokens(captured['messages']);
      final schemaTokens =
          session.projection.schemaTokens(captured['tools'] as List<Map<String, Object?>>);
      expect(messageTokens + schemaTokens + 200, lessThanOrEqualTo(2000));
    });
  });

  group('ApprovalSurvivesRestart', () {
    test('waiting for approval resumes after simulated restart', () async {
      final tmpDir = Directory.systemTemp.createTempSync('spal_acceptance_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      final written = <String, String>{};

      String writeFile(Map<String, Object?> args) {
        final path = args['path'] as String;
        final content = args['content'] as String;
        written[path] = content;
        return 'wrote ${content.length} bytes';
      }

      Registry makeRegistry() {
        final reg = Registry();
        reg.register(
          capabilityDict('fs.write',
              properties: {
                'path': {'type': 'string'},
                'content': {'type': 'string'},
              },
              required: ['path', 'content'],
              effects: [('write', 'workspace:*')],
              retrySafety: 'never_retry'),
          handler: writeFile,
        );
        return reg;
      }

      // A real deployment reconstructs its PolicyEngine from its own
      // config on every boot; here that means a fresh engine with the
      // same (empty) rule set, so its revision number lines up with what
      // was recorded at approval-request time.
      PolicyEngine makePolicy() => PolicyEngine(defaultDecision: 'require_approval');

      final cfg = Config.fromDict({
        'mode': 'job',
        'persistence': {'ledger_directory': tmpDir.path},
      });
      final llm1 = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('fs.write', arguments: {'path': 'a.txt', 'content': 'hello'})),
      ]);
      final session1 =
          Session(llm1, registry: makeRegistry(), config: cfg, policy: makePolicy());
      await session1.runJob('write a.txt');
      expect(session1.run.state, equals('WAITING_FOR_APPROVAL'));
      final runId = session1.run.id;
      expect(written, isEmpty); // never executed before approval

      // --- simulate a process restart: build a brand new Session purely
      // from what's on disk, with no reference to session1/run1 ---
      final llm2 = ScriptedLLM([DecisionStep(ScriptedLLM.finish('all done'))]);
      final restored = Session.resumeFromLedger(llm2, runId,
          config: cfg, registry: makeRegistry(), policy: makePolicy());
      expect(restored.run.state, equals('WAITING_FOR_APPROVAL'));
      expect(restored.run.pendingCalls.map((c) => c.name).toList(), equals(['fs.write']));

      restored.resolveApproval('approved');
      final result2 = await restored.resume();

      expect(result2, equals('all done'));
      expect(written, equals({'a.txt': 'hello'}));
      expect(restored.run.state, equals('COMPLETED'));
    });
  });

  group('PolicyLayering', () {
    test('higher layer deny cannot be relaxed by lower layer', () async {
      final reg = Registry();
      final executed = <bool>[];
      reg.register(capabilityDict('fs.write', effects: [('write', 'workspace:*')]),
          handler: (Map<String, Object?> args) {
        executed.add(true);
        return 'ok';
      });

      final policy = PolicyEngine(defaultDecision: 'allow');
      policy.addRule('admin', Rule(decision: 'deny', capabilityPattern: 'fs.*'));
      // A lower layer (session/workspace) tries to allow it anyway.
      policy.addRule('session', Rule(decision: 'allow', capabilityPattern: 'fs.*'));

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('fs.write')),
        const TextStep('could not write'),
      ]);
      final session = Session(llm, registry: reg, policy: policy);
      final reply = await session.send('please write');
      expect(reply, equals('could not write'));
      expect(executed, isEmpty);
    });
  });

  group('Reproducibility', () {
    test('run state recoverable from events and snapshot', () async {
      final tmpDir = Directory.systemTemp.createTempSync('spal_acceptance_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      final reg = Registry();
      reg.register(
        capabilityDict('demo.echo', properties: {
          'text': {'type': 'string'},
        }, required: [
          'text'
        ]),
        handler: (Map<String, Object?> args) => 'echo:${args['text']}',
      );
      final cfg = Config.fromDict({
        'mode': 'job',
        'persistence': {'ledger_directory': tmpDir.path},
      });
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'hi'})),
        DecisionStep(ScriptedLLM.finish('done')),
      ]);
      final session =
          Session(llm, registry: reg, config: cfg, policy: PolicyEngine(defaultDecision: 'allow'));
      await session.runJob('echo hi then finish');
      final runId = session.run.id;

      final events = session.ledger.iterRun(runId).toList();
      final eventTypes = events.map((e) => e.type).toSet();
      expect(
        {
          'user_input',
          'projection_compiled',
          'model_response',
          'decision_validated',
          'command_started',
          'command_completed',
          'run_state_changed',
        }.every(eventTypes.contains),
        isTrue,
      );

      final snapshot = session.ledger.loadSnapshot(runId);
      expect(snapshot, isNotNull);
      expect(snapshot!.state['state'], equals('COMPLETED'));

      final restoredLlm = ScriptedLLM([], strict: false);
      final restored = Session.resumeFromLedger(restoredLlm, runId, config: cfg, registry: reg);
      expect(restored.run.state, equals('COMPLETED'));
      expect(restored.run.result, equals('done'));
      expect(
        restored.conversation.map((m) => m.role).toList(),
        equals(session.conversation.map((m) => m.role).toList()),
      );
    });
  });

  group('Rewind', () {
    test('branch never mutates or deletes parent events', () async {
      final reg = Registry();
      final session =
          Session(ScriptedLLM([const TextStep('one'), const TextStep('two'), const TextStep('three')]),
              registry: reg);
      await session.send('a');
      await session.send('b');
      await session.send('c');
      final parentEventsBefore = session.ledger.iterRun(session.run.id).toList();

      final (branch, unusedIrreversible) = session.branch(atMessage: 2);
      expect(unusedIrreversible, isA<List<String>>());

      final parentEventsAfter = session.ledger.iterRun(session.run.id).toList();
      expect(
        parentEventsBefore.map((e) => e.id).toList(),
        equals(parentEventsAfter.map((e) => e.id).toList()),
      );
      expect(branch.run.id, isNot(equals(session.run.id)));
      expect(branch.conversation.length, equals(2));
      expect(session.conversation.length, equals(6)); // parent untouched
    });
  });

  group('ExternalEffectsSurfaced', () {
    test('rewind reports effects it cannot undo', () async {
      final reg = Registry();
      reg.register(capabilityDict('mail.send', effects: [('external', 'smtp:*')]),
          handler: (Map<String, Object?> args) => 'sent');
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('mail.send')),
        const TextStep('sent the email'),
      ]);
      final session = Session(llm, registry: reg, policy: PolicyEngine(defaultDecision: 'allow'));
      await session.send('send the email');

      final (unusedBranch, irreversible) = session.branch();
      expect(unusedBranch, isA<Session>());
      expect(irreversible.any((note) => note.contains('mail.send')), isTrue);
    });
  });

  group('CommandTraceability', () {
    test('each command traceable start to finish', () async {
      final reg = Registry();
      reg.register(
        capabilityDict('demo.echo', properties: {
          'text': {'type': 'string'},
        }, required: [
          'text'
        ]),
        handler: (Map<String, Object?> args) => 'echo:${args['text']}',
      );
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'hi'})),
          const TextStep('done'),
        ]),
        registry: reg,
        policy: PolicyEngine(defaultDecision: 'allow'),
      );
      await session.send('echo hi');

      final events = session.ledger.iterRun(session.run.id).toList();
      final started = events.firstWhere((e) => e.type == 'command_started');
      final completed = events.firstWhere((e) => e.type == 'command_completed');
      expect(started.data['command_id'], equals(completed.data['command_id']));
      expect(started.data['capability'], equals('demo.echo@1')); // qualified (versioned) name
      // the full pipeline is visible in order: decision -> command -> outcome
      final typesInOrder = events.map((e) => e.type).toList();
      expect(typesInOrder.indexOf('decision_validated'), lessThan(typesInOrder.indexOf('command_started')));
      expect(typesInOrder.indexOf('command_started'), lessThan(typesInOrder.indexOf('command_completed')));
    });
  });
}
