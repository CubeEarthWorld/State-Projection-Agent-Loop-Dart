// Regression tests for verified bugs in the leaf modules (artifacts,
// serialization, json_schema, llm, events, memory).
//
// Each test is named for the bug it pins; the Python reference carries the
// mirror of this file at `tests/unit/test_regressions.py`.
import 'dart:convert';
import 'dart:io';

import 'package:state_projection_loop/src/artifacts.dart';
import 'package:state_projection_loop/src/events.dart';
import 'package:state_projection_loop/src/json_schema.dart';
import 'package:state_projection_loop/src/llm.dart';
import 'package:state_projection_loop/src/memory.dart';
import 'package:state_projection_loop/src/messages.dart';
import 'package:state_projection_loop/src/serialization.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('spal_regressions'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // B1: `aid` is model-controlled and reaches the filesystem.
  group('ArtifactIdIsNotAPath', () {
    test('an id can never address another run', () {
      final victim = ArtifactStore('run_X', directory: tmp.path);
      final record = victim.put({'secret': 's3cret'});
      final attacker = ArtifactStore('run_OTHER', directory: tmp.path);
      final escape = '../run_X/${record.id}';
      expect(attacker.exists(escape), isFalse);
      expect(attacker.resolveArgs({r'$artifact': escape}), equals({r'$artifact': escape}));
      // The run that owns it still resolves it.
      expect(victim.exists(record.id), isTrue);
    });

    test('separators, absolute paths and empty ids are rejected', () {
      final store = ArtifactStore('run_X', directory: tmp.path);
      for (final aid in ['..', '../x', 'a/b', r'a\b', '/etc/passwd', 'C:/Windows/x', '', 'art_x.json']) {
        expect(store.exists(aid), isFalse, reason: aid);
        expect(store.peek(aid), contains('Error: unknown artifact'));
      }
    });
  });

  // B2: NaN/Infinity broke the two ports in opposite directions.
  group('DumpsNonFinite', () {
    test('non-finite doubles become null', () {
      expect(dumps({'s': double.nan}), equals('{"s":null}'));
      expect(dumps([double.infinity, double.negativeInfinity]), equals('[null,null]'));
      expect(dumps(double.nan), equals('null'));
    });

    test('the output is still valid JSON', () {
      expect(
        jsonDecode(dumps({
          'a': [double.nan],
          'b': {'c': double.infinity},
        })),
        equals({
          'a': [null],
          'b': {'c': null},
        }),
      );
    });

    test('an event carrying one still appends', () {
      final ledger = JsonlLedger(tmp.path);
      final event = ledger.append('run_1', 'notice', {'text': 'x', 'ratio': double.nan});
      expect(event.sequence, equals(1));
      expect(ledger.iterRun('run_1').single.data['ratio'], isNull);
    });
  });

  // B3: a fenced block need not decode to an object.
  group('FencedToolCallParsing', () {
    test('a non-object block is ignored', () {
      for (final body in ['[1,2]', '7', '"x"', 'null', 'true']) {
        final (cleaned, calls) = parseTextToolCalls('before\n```tool_call\n$body\n```\nafter');
        expect(calls, isEmpty);
        expect(cleaned, equals('before\n\nafter'));
      }
    });
  });

  // B4: a bad capability spec must degrade, not crash.
  group('MalformedSchema', () {
    test('a non-list enum is ignored', () {
      expect(validateValue({'enum': 'abc'}, 'a'), isNull);
    });

    test('a non-string type is ignored', () {
      expect(validateValue({'type': 7}, 'x'), isNull);
    });

    test('a string required names its characters', () {
      expect(validateValue({'required': 'ab'}, {}),
          equals('arguments: missing required property "a"'));
    });
  });

  // B5: object and array enum members must compare structurally.
  group('EnumMatching', () {
    test('structural members match', () {
      expect(
          validateValue({
            'enum': [
              {'a': 1}
            ]
          }, {'a': 1}),
          isNull);
      expect(
          validateValue({
            'enum': [
              [1, 2]
            ]
          }, [1, 2]),
          isNull);
      // The documented `==` wart of the Python reference.
      expect(validateValue({'enum': [true]}, 1), isNull);
    });

    test('a different structure still fails', () {
      expect(
          validateValue({
            'enum': [
              {'a': 1}
            ]
          }, {'a': 2}),
          isNotNull);
      expect(
          validateValue({
            'enum': [
              [1, 2]
            ]
          }, [1, 3]),
          isNotNull);
    });
  });

  // B6: `exists` is a predicate, not a parser.
  group('ExistsIsTotal', () {
    test('a corrupt or foreign file reads as absent', () {
      final store = ArtifactStore('run_X', directory: tmp.path);
      final runDir = Directory('${tmp.path}/run_X')..createSync(recursive: true);
      File('${runDir.path}/art_TORN.json').writeAsStringSync('{"id":"art_TORN","run');
      File('${runDir.path}/art_FOREIGN.json').writeAsStringSync('{"hello":1}');
      expect(store.exists('art_TORN'), isFalse);
      expect(store.exists('art_FOREIGN'), isFalse);
      expect(store.peek('art_TORN'), contains('Error: unknown artifact'));
    });
  });

  // B7: an unbuffered append can be cut in half by a crash.
  group('TornJsonlLines', () {
    test('the ledger still replays', () {
      JsonlLedger(tmp.path).append('run_1', 'notice', {'text': 'kept'});
      File('${tmp.path}/run_1.jsonl')
          .writeAsStringSync('{"id":"evt_x","run_id":"run', mode: FileMode.append);
      expect([for (final e in JsonlLedger(tmp.path).iterRun('run_1')) e.data['text']],
          equals(['kept']));
    });

    test('the memory store still constructs', () {
      final path = '${tmp.path}/memory.jsonl';
      JsonlMemoryStore(path).save('tabs over spaces', ['style']);
      File(path).writeAsStringSync('{"id":"note_x","te', mode: FileMode.append);
      expect([for (final n in JsonlMemoryStore(path).search('tabs', 5)) n.text],
          equals(['tabs over spaces']));
    });

    test('an unknown note field is ignored', () {
      final path = '${tmp.path}/memory.jsonl';
      File(path).writeAsStringSync('{"id":"n1","text":"hi there","tags":[],"ts":1.0,"future":true}\n');
      expect(JsonlMemoryStore(path).search('hi', 5), hasLength(1));
    });
  });

  // B8: the caller keeps its Decision (Dart already copied; pinned so the
  // two ports cannot drift apart again).
  group('ExtractFinishCopies', () {
    test('the argument is left alone', () {
      final original = Decision(
          text: 'bye',
          calls: [
            ToolCall(name: finishName, arguments: {'result': 'done'})
          ]);
      final returned = extractFinish(original);
      expect(identical(returned, original), isFalse);
      expect(returned.finish, isTrue);
      expect(returned.result, equals('done'));
      expect(returned.calls, isEmpty);
      expect(original.finish, isFalse);
      expect(original.result, isNull);
      expect(original.calls, hasLength(1));
    });

    test('a decision without finish passes straight through', () {
      final original = Decision(calls: [ToolCall(name: 'demo.echo', arguments: {})]);
      expect(identical(extractFinish(original), original), isTrue);
    });
  });
}
