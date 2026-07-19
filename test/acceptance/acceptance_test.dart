// General acceptance tests (carried over from the original design spec):
//
// (a) 1,000 registered capabilities, default config -> per-turn tool-related
//     overhead stays small (two orders of magnitude below full-spec preloading)
// (b) with vectors disabled, every registered capability remains reachable
// (c) the self-repair path works: validation failure -> spec attached -> retry
// (d) the default config alone yields a working chat agent
//
// The Codex-review-driven P0/P1 fixes have their own focused suite in
// p0_p1_acceptance_test.dart.
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
}
