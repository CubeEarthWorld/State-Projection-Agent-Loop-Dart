/// The prompt a provider caches is the tools array, then the messages up to
/// the volatile tail. These tests pin the two things that used to move under
/// it: the native tool list (re-ranked every step) and the history boundaries
/// after a rewind or branch (left pointing at the old run's sequence
/// numbers). Asserted on what actually reaches the adapter.
///
/// Port of `tests/unit/test_prefix_stability.py`.
library;

import 'dart:io';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:state_projection_loop/src/serialization.dart';
import 'package:test/test.dart';

import '../util.dart';

final long = 'line\n' * 100;

Registry _registry() {
  final registry = Registry();
  for (final (name, words) in [
    ('weather.forecast.get', 'weather forecast rain sunny'),
    ('calendar.event.add', 'calendar event schedule meeting'),
    ('mail.message.send', 'mail email message send'),
    ('notes.note.write', 'notes note write memo'),
  ]) {
    registry.register(
      capabilityDict(name,
          description: '$name tool.',
          properties: {
            'text': {'type': 'string'}
          },
          embeddingText: words,
          effects: [('read', 'workspace:*')]),
      handler: (Map<String, Object?> args) => echoHandlerText('${args['text'] ?? ''}'),
    );
  }
  return registry;
}

List<Message> _messages(Map<String, Object?> request) =>
    (request['messages'] as List).cast<Message>();
List<Map<String, Object?>> _tools(Map<String, Object?> request) =>
    (request['tools'] as List).cast<Map<String, Object?>>();
List<String> _toolNames(Map<String, Object?> request) =>
    [for (final t in _tools(request)) t['name'] as String];

String _wire(Message m) => dumps([
      m.role,
      m.content,
      m.toolCallId,
      [for (final c in m.toolCalls) c.toDict()]
    ]);

/// The tools array and every message before the trailing system block
/// (working state, checklists, candidates: volatile by design), as bytes.
(String, List<String>) _stablePart(Map<String, Object?> request) {
  final messages = List.of(_messages(request));
  while (messages.isNotEmpty && messages.last.role == kSystem) {
    messages.removeLast();
  }
  return (dumps(_tools(request)), [for (final m in messages) _wire(m)]);
}

List<String> _wires(Map<String, Object?> request) => [for (final m in _messages(request)) _wire(m)];

Config _tiered() => Config.fromDict({
      'compression': {'full_window': 2},
      'compaction': {'trigger_ratio': 0},
    });

Config _noCandidates([Map<String, Object?> discovery = const {}]) => Config.fromDict({
      'discovery': {'query_sources': <String>[], ...discovery},
    });

void main() {
  group('native tools stay put', () {
    test('the tools array only ever grows at the end', () async {
      // Candidates change with every message; the native list must not
      // reorder or lose an entry because of it.
      final messages = [
        'weather forecast please',
        'schedule a calendar meeting',
        'rain tomorrow? weather',
        'send an email message',
        'weather forecast again',
      ];
      final llm = ScriptedLLM([for (var i = 0; i < messages.length; i++) TextStep('ok $i')]);
      final session = Session(llm, registry: _registry(), policy: allowAll());
      for (final text in messages) {
        await session.send(text);
      }
      final sent = [for (final r in llm.requests) _toolNames(r)];
      for (var i = 1; i < sent.length; i++) {
        expect(sent[i].take(sent[i - 1].length).toList(), sent[i - 1],
            reason: '${sent[i]} does not extend ${sent[i - 1]}');
      }
      expect({for (final s in sent) s.join(',')}.length, greaterThan(1),
          reason: 'the scenario must surface new tools along the way');
      expect(sent[4], sent[3],
          reason: 'a turn whose candidates were all offered already sends the same tools');
    });

    test('the cached prefix is byte identical when only candidates change', () async {
      final llm = ScriptedLLM(const [TextStep('one'), TextStep('two'), TextStep('three')]);
      final session = Session(llm, registry: _registry(), policy: allowAll());
      // Surfaces every tool.
      await session.send('weather forecast and calendar schedule, email and notes');
      await session.send('weather');
      await session.send('calendar');
      final parts = [for (final r in llm.requests) _stablePart(r)];
      // The same tools, and each request's messages the previous ones plus the new turn.
      expect(parts[1].$1, parts[0].$1);
      expect(parts[2].$1, parts[0].$1);
      for (var i = 1; i < parts.length; i++) {
        final (_, before) = parts[i - 1];
        final (_, after) = parts[i];
        expect(after.take(before.length).toList(), before);
        expect(after.length, greaterThan(before.length));
      }
      // The ranking still reaches the model, at the tail.
      final tail =
          _messages(llm.requests[1]).where((m) => m.role == kSystem).last.content as String;
      expect(tail, startsWith('[Tool candidates'));
    });

    test('using a tool does not move it', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('mail.message.send', arguments: {'text': 'a'})),
        const TextStep('sent'),
        DecisionStep(ScriptedLLM.call('weather.forecast.get', arguments: {'text': 'b'})),
        const TextStep('rain'),
        DecisionStep(ScriptedLLM.call('mail.message.send', arguments: {'text': 'c'})),
        const TextStep('sent again'),
      ]);
      final session =
          Session(llm, registry: _registry(), config: _noCandidates(), policy: allowAll());
      for (final text in ['one', 'two', 'three']) {
        await session.send(text);
      }
      expect(session.nativeTools, ['mail.message.send', 'weather.forecast.get']);
      final last = _toolNames(llm.requests.last);
      expect(last.sublist(last.length - 2), ['mail__message__send', 'weather__forecast__get']);
    });

    test('the list is capped by activeTools, least recent out', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('mail.message.send', arguments: {'text': 'a'})),
        DecisionStep(ScriptedLLM.call('weather.forecast.get', arguments: {'text': 'b'})),
        DecisionStep(ScriptedLLM.call('mail.message.send', arguments: {'text': 'c'})),
        DecisionStep(ScriptedLLM.call('notes.note.write', arguments: {'text': 'd'})),
        const TextStep('done'),
      ]);
      final session = Session(llm,
          registry: _registry(), config: _noCandidates({'active_tools': 2}), policy: allowAll());
      await session.send('go');
      expect(session.nativeTools, ['mail.message.send', 'notes.note.write']);
    });

    test('a resumed run sends the same tools', () async {
      final dir = Directory.systemTemp.createTempSync('spal_tools_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final config = Config.fromDict({
        'discovery': {'query_sources': <String>[]},
        'persistence': {'ledger_directory': dir.path},
      });
      final firstLlm = ScriptedLLM([
        DecisionStep(
            ScriptedLLM.call('meta.tool.find', arguments: {'query': 'calendar schedule meeting'})),
        const TextStep('found'),
      ]);
      final first = Session(firstLlm, registry: _registry(), config: config, policy: allowAll());
      await first.send('find me a calendar tool');
      expect(first.nativeTools, contains('calendar.event.add'));

      final llm = ScriptedLLM(const [TextStep('again')]);
      final resumed = Session.resumeFromLedger(llm, first.run.id,
          config: config, registry: _registry(), policy: allowAll());
      expect(resumed.nativeTools, first.nativeTools);
      await resumed.send('next');
      expect(dumps(_tools(llm.requests.first)), dumps(_tools(firstLlm.requests.last)));
    });

    test('rewind puts back the tools that turn began with', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('mail.message.send', arguments: {'text': 'a'})),
        const TextStep('sent'),
        DecisionStep(ScriptedLLM.call('weather.forecast.get', arguments: {'text': 'b'})),
        const TextStep('rain'),
      ]);
      final session =
          Session(llm, registry: _registry(), config: _noCandidates(), policy: allowAll());
      await session.send('one');
      await session.send('two');
      expect(session.nativeTools, ['mail.message.send', 'weather.forecast.get']);
      session.rewind(toTurn: 1);
      expect(session.nativeTools, ['mail.message.send']);
    });

    test('the window drops the least recently used schema first', () {
      // The array is in first-sent order, so its first entry is not the one
      // that matters least; the recency the session hands over is.
      final registry = _registry();
      final mail = registry.get('mail.message.send')!.toolSpec();
      final notes = registry.get('notes.note.write')!.toolSpec();
      final probe = Projection([]);
      final room = [
        probe.schemaTokens([mail]),
        probe.schemaTokens([notes])
      ].reduce((a, b) => a > b ? a : b);
      final ctx = TurnContext(
          config: Config(),
          registry: registry,
          toolRecency: ['notes__note__write', 'mail__message__send']);
      Projection([], windowTokens: room).render(ctx, apiTools: [mail, notes]);
      expect([for (final t in ctx.apiTools) t['name']], ['mail__message__send']);
    });
  });

  group('rewind carries the history boundaries', () {
    test('resending after a rewind reproduces the original request', () async {
      // Rewinding to turn t and sending the same message again must render
      // exactly what turn t rendered the first time. The copied history is
      // renumbered; a verbatim point left at the old run's number lands past
      // it and compresses everything that should have been verbatim.
      final replies = [for (var i = 0; i < 6; i++) 'reply $i $long'];
      final llm = ScriptedLLM([
        for (final r in [...replies, replies[5]]) TextStep(r)
      ]);
      final session = Session(llm, config: _tiered());
      for (var i = 0; i < 6; i++) {
        await session.send('msg $i');
      }
      session.rewind(toTurn: 5);
      await session.send('msg 5');
      expect(_wires(llm.requests.last), _wires(llm.requests[5]));
    });

    test('the fold point is carried too', () async {
      final session = Session(ScriptedLLM([for (var i = 0; i < 4; i++) TextStep('reply $i')]),
          config: _tiered());
      for (var i = 0; i < 4; i++) {
        await session.send('msg $i');
      }
      List<Event> exchange() => [
            for (final e in session.ledger.iterRun(session.run.id))
              if (e.type == 'user_input' || e.type == 'model_response') e,
          ];
      final events = exchange();
      // As if a fold had absorbed the first exchange before turn 3 began.
      final checkpoint = session.ledger
          .iterRun(session.run.id)
          .firstWhere((e) => e.type == 'checkpoint' && e.sequence > events[6].sequence);
      final ws = checkpoint.data['working_state'] as Map;
      ws['folded_sequence'] = events[1].sequence;
      ws['verbatim_sequence'] = events[4].sequence;
      session.rewind(toTurn: 3);
      final kept = exchange();
      expect(session.workingState.foldedSequence, kept[1].sequence);
      expect(session.workingState.verbatimSequence, kept[4].sequence);
    });

    test('rewinding twice restores the earlier turn\'s state', () async {
      // The first rewind used to copy only the messages, so a second rewind
      // found the first rewind's checkpoint for every turn.
      final registry = Registry();
      installBuiltins(registry, ['state']);
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('state.goal.set', arguments: {'text': 'A'})),
          const TextStep('ok'),
          DecisionStep(ScriptedLLM.call('state.goal.set', arguments: {'text': 'B'})),
          const TextStep('ok'),
          const TextStep('r2'),
        ]),
        registry: registry,
        policy: allowAll(),
      );
      for (final text in ['t0', 't1', 't2']) {
        await session.send(text);
      }
      session.rewind(toTurn: 2);
      expect(session.workingState.goal, 'B');
      session.rewind(toTurn: 1);
      expect(session.workingState.goal, 'A');
    });

    test('a branch can be rewound', () async {
      final registry = Registry();
      installBuiltins(registry, ['state']);
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('state.goal.set', arguments: {'text': 'A'})),
          const TextStep('ok'),
          DecisionStep(ScriptedLLM.call('state.goal.set', arguments: {'text': 'B'})),
          const TextStep('ok'),
        ]),
        registry: registry,
        policy: allowAll(),
      );
      await session.send('t0');
      await session.send('t1');
      final (branch, _) = session.branch();
      branch.rewind(toTurn: 1);
      expect(branch.workingState.goal, 'A');
    });

    test('a branch renders its history as the parent does', () async {
      final replies = [for (var i = 0; i < 7; i++) 'reply $i $long'];
      final llm = ScriptedLLM([
        for (final r in replies) TextStep(r),
        const TextStep('same'),
        const TextStep('same'),
      ]);
      final session = Session(llm, config: _tiered());
      for (var i = 0; i < 7; i++) {
        await session.send('msg $i');
      }
      final (branch, _) = session.branch();
      await session.send('next');
      await branch.send('next');
      expect(_wires(llm.requests.last), _wires(llm.requests[llm.requests.length - 2]));
    });
  });
}
