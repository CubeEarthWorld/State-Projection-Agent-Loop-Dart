// History compression as the model sees it over a long run: the verbatim
// point moves in steps, old tool results are masked but errors stay
// readable, the user's words are never touched, and between steps the
// rendered prefix is byte-identical (what a provider's prompt cache needs).
import 'package:state_projection_loop/src/compression.dart' show maskObservation, ungrounded;
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

final noise = [for (var i = 0; i < 30; i++) 'line $i: filler'].join('\n');

List<String> historyTexts(Session session) {
  final ctx = TurnContext(
      config: session.config,
      registry: session.registry,
      ledger: session.ledger,
      run: session.run,
      workingState: session.workingState);
  return [for (final m in session.projection.get('history')!.render(ctx)) m.content.toString()];
}

Registry registry() {
  final reg = Registry();
  reg.register(capabilityDict('demo.lookup', properties: {'id': {'type': 'string'}}),
      handler: (args) => 'record ${args['id']}\n$noise\namount: ${(args['id'] as String).length * 100} EUR');
  reg.register(capabilityDict('demo.broken'), handler: (args) => 'Traceback\n$noise\nValueError: bad id');
  return reg;
}

/// A session scripted for [turns] lookups; sent already unless [send] is false.
Future<Session> drive(int turns, {int fullWindow = 2, String tool = 'demo.lookup', bool send = true}) async {
  final steps = <Step>[];
  for (var i = 0; i < turns; i++) {
    steps.add(DecisionStep(ScriptedLLM.call(tool, arguments: tool == 'demo.lookup' ? {'id': 'r$i'} : {})));
    steps.add(TextStep('reply $i'));
  }
  final session = Session(ScriptedLLM(steps),
      registry: registry(),
      policy: allowAll(),
      builtins: const [],
      config: Config.fromDict({'compression': {'full_window': fullWindow}}));
  for (var i = 0; i < (send ? turns : 0); i++) {
    await session.send('look up r$i');
  }
  return session;
}

void main() {
  group('tiers move in steps', () {
    test('the verbatim point moves in steps, not every turn', () async {
      final session = await drive(6, fullWindow: 2, send: false);
      final points = <int>[];
      for (var i = 0; i < 6; i++) {
        await session.send('look up r$i'); // 4 messages a turn: user, decision, result, reply
        points.add(session.workingState.verbatimSequence);
      }
      expect(points.first, 0);
      expect(points.toSet().length, lessThan(points.length), reason: 'the point must not move every turn');
      expect(points, [...points]..sort());
    });

    test('between steps the rendered prefix is byte-identical', () async {
      final session = await drive(6, fullWindow: 3, send: false);
      final renders = <List<String>>[];
      for (var i = 0; i < 6; i++) {
        await session.send('look up r$i');
        renders.add(historyTexts(session));
      }
      var stable = 0;
      for (var i = 1; i < renders.length; i++) {
        final previous = renders[i - 1];
        final current = renders[i];
        if (current.length >= previous.length &&
            [for (var j = 0; j < previous.length; j++) current[j] == previous[j]].every((same) => same)) {
          stable += 1;
        }
      }
      expect(stable, greaterThanOrEqualTo(3), reason: 'only $stable of 5 consecutive renders extended the previous one');
    });
  });

  group('what each tier keeps', () {
    test('old tool results are masked but errors stay readable', () async {
      final ok = await drive(6, fullWindow: 1);
      var texts = historyTexts(ok);
      expect(texts.where((t) => t.startsWith('record r') && t.contains('[') && t.contains('lines')), isNotEmpty,
          reason: 'an old lookup result should be cleared to its first line and size');
      expect(texts.sublist(0, texts.length - 3).any((t) => t.contains('line 29: filler')), isFalse);

      final broken = await drive(6, fullWindow: 1, tool: 'demo.broken');
      texts = historyTexts(broken);
      expect(texts.sublist(0, texts.length - 3).any((t) => t.contains('ValueError: bad id')), isTrue,
          reason: 'the tail of an old error must survive');
    });

    test('user messages are never compressed or dropped', () async {
      final session = await drive(40, fullWindow: 1);
      session.config.compression.compressedWindow = 2;
      session.config.compression.summaryWindow = 2;
      final texts = historyTexts(session);
      expect(texts.where((t) => t.startsWith('look up r')).toList(), [for (var i = 0; i < 40; i++) 'look up r$i']);
    });

    test('masking is the first line and size unless it is an error', () {
      expect(maskObservation('ok\n$noise'), startsWith('ok  ['));
      expect(maskObservation('exit=1\n$noise', maxLines: 10), contains('line 29'));
      expect(maskObservation('ok\n$noise', maxLines: 10, failed: true), contains('line 29'),
          reason: 'a failed call keeps its tail');
    });

    test('errors are recognised whatever the language', () {
      for (final report in [
        '処理に失敗しました',
        'エラー: ファイルが見つかりません',
        '错误：找不到文件',
        '오류가 발생했습니다',
        'Fehler beim Lesen',
        'Ошибка чтения',
        'returncode: 2',
        '  File "x.py", line 3, in main',
      ]) {
        expect(maskObservation('$report\n$noise', maxLines: 10), contains('line 29'), reason: report);
      }
      expect(maskObservation('完了しました\n$noise'), startsWith('完了しました  ['));
    });
  });

  group('grounded folds', () {
    test('an entry naming what the transcript never said is dropped', () {
      final ws = WorkingState();
      final delta = <String, Object?>{
        'facts_add': ['invoice INV-100 is paid', 'invoice INV-999 is paid'],
        'next_actions': ['ship order 100'],
      };
      expect(applyFoldDelta(ws, delta, transcript: 'user: invoice INV-100 is paid\nassistant: noted order 100'),
          isNull);
      expect(ws.confirmedFacts, ['invoice INV-100 is paid']);
      expect(ws.nextActions, ['ship order 100']);
      expect(delta['ungrounded'], ['invoice INV-999 is paid (unknown: INV-999)']);
    });

    test('plain words need no grounding', () {
      expect(ungrounded('the user prefers short answers', ''), isEmpty);
    });
  });
}
