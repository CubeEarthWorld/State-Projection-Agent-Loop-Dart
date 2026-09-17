import 'dart:convert';
import 'dart:io';
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

const tool = 'planning.checklist.manage';

class FailingLedger extends InMemoryLedger {
  @override
  Event append(String runId, String type, Map<String, Object?> data) {
    if (type == 'checklists_changed') throw StateError('disk unavailable');
    return super.append(runId, type, data);
  }
}

Map<String, Object?> plan(ChecklistStore store) => store.execute('create', {
      'name': '出荷計画',
      'items': [
        {'text': '実装'},
        {'text': '検証'}
      ],
    }) as Map<String, Object?>;

Map<String, Object?> edit(
        ChecklistStore store, Map value, Map<String, Object?> args,
        [String action = 'update']) =>
    store.execute(action, {
      'id': value['id'],
      'expected_revision': value['revision'],
      ...args
    }) as Map<String, Object?>;

void main() {
  test('ledger failure does not apply edit', () async {
    final session = Session(ScriptedLLM([]), ledger: FailingLedger());
    await expectLater(
        session.invoke(tool, {'action': 'create', 'name': 'not committed'}),
        throwsStateError);
    expect(session.checklists.isEmpty, true);
  });

  test('native schema dedup keeps text fallback', () {
    final session = Session(ScriptedLLM([]));
    final turn = TurnContext(
        config: session.config,
        registry: session.registry,
        ledger: session.ledger,
        run: session.run);
    final kernel = session.projection.get('kernel')!;
    expect(kernel.render(turn).first.content.toString(),
        contains('Parameters (JSON Schema)'));
    turn.apiTools = [for (final c in session.registry.pinned()) c.apiSchema()];
    expect(kernel.render(turn).first.content.toString(),
        isNot(contains('Parameters (JSON Schema)')));
    expect(kernel.render(turn).first.content.toString(), contains(tool));
    turn.apiTools.removeLast();
    expect(kernel.render(turn).first.content.toString(),
        contains('Parameters (JSON Schema)'));
  });

  test('shared wire fixture', () {
    final document =
        jsonDecode(File('test/fixtures/checklists_v1.json').readAsStringSync())
            as Map;
    final store = ChecklistStore.fromDict(document);
    expect(store.toDict(), document);
    final value = store.execute('get',
        {'id': ((document['checklists'] as List).first as Map)['id']}) as Map;
    expect(value['status'], 'in_progress');
    expect(value['progress'], {
      'total': 3,
      'pending': 0,
      'in_progress': 1,
      'blocked': 0,
      'completed': 1,
      'cancelled': 1,
      'remaining': 1,
      'fraction': .5
    });
  });

  test('projection budget never deletes plans', () async {
    final cfg = Config.fromMap({
      'projection': {'window_tokens': 2000, 'reserved_output_tokens': 200}
    });
    final llm = ScriptedLLM([const TextStep('ok')]);
    final session = Session(llm, config: cfg);
    for (var i = 0; i < 12; i++) {
      session.checklists.execute('create', {
        'name': 'plan $i',
        'context_mode': 'full',
        'items': List.filled(30, {'text': 'x' * 500})
      });
    }
    await session.send('work');
    final request = llm.requests.last;
    expect(
        estimateTokens(request['messages']) +
            session.projection.schemaTokens(
                (request['tools'] as List).cast<Map<String, Object?>>()) +
            200,
        lessThanOrEqualTo(2000));
    expect((session.checklists.execute('list') as List).length, 12);
    expect(
        (((session.checklists.execute('list', {'mode': 'full'}) as List).first
                as Map)['items'] as List)
            .length,
        30);
  });

  test('memory default and persisted branch/rewind', () async {
    final memory = Session(ScriptedLLM([]));
    await memory.invoke(tool, {'action': 'create', 'name': 'memory'});
    expect(memory.ledger, isA<InMemoryLedger>());
    expect(memory.config.persistence.ledgerDirectory, isNull);
    expect(Session(ScriptedLLM([])).checklists.isEmpty, true);
    final dir = Directory.systemTemp.createTempSync('checklist-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cfg = Config.fromMap({
      'persistence': {'ledger_directory': dir.path}
    });
    final session = Session(
        ScriptedLLM([const TextStep('one'), const TextStep('two')]),
        config: cfg);
    await session.invoke(tool, {'action': 'create', 'name': 'persist'});
    await session.send('first');
    final (child, _) = session.branch();
    final restartedChild =
        Session.resumeFromLedger(ScriptedLLM([]), child.run.id, config: cfg);
    expect(restartedChild.checklists.toDict(), session.checklists.toDict());
    await session.send('second');
    session.rewind(toTurn: 1);
    final restarted =
        Session.resumeFromLedger(ScriptedLLM([]), session.run.id, config: cfg);
    expect(restarted.checklists.toDict(), session.checklists.toDict());
  });

  test('CRUD, progress, and revision conflicts', () {
    final store = ChecklistStore();
    var value = plan(store);
    expect((value['id'] as String).length, 26);
    final first = ((value['items'] as List).first as Map)['id'];
    value = edit(
        store,
        value,
        {
          'item_id': first,
          'item': {'status': 'completed', 'notes': 'tests passed'}
        },
        'update_item');
    expect((value['progress'] as Map)['fraction'], .5);
    final before = store.toDict();
    expect(
        () => store
            .execute('delete', {'id': value['id'], 'expected_revision': 1}),
        throwsArgumentError);
    expect(store.toDict(), before);
    value = edit(
        store,
        value,
        {
          'item': {'text': 'publish'}
        },
        'add_item');
    value = edit(
        store,
        value,
        {'item_id': ((value['items'] as List).last as Map)['id']},
        'delete_item');
    value = edit(store, value, {
      'items': [
        for (final x in value['items'] as List)
          {...(x as Map), 'status': 'completed'}
      ]
    });
    expect(value['status'], 'completed');
    expect((value['progress'] as Map)['fraction'], 1);
    expect(((store.execute('list') as List).first as Map).containsKey('items'),
        false);
    edit(store, value, {}, 'delete');
    expect(store.execute('list'), isEmpty);
  });

  final invalid = <Map<String, Object?>>[
    {'name': ' '},
    {'include_in_context': 1},
    {'context_mode': 'bogus'},
    {
      'items': [
        {'text': 'a', 'status': 'in_progress'},
        {'text': 'b', 'status': 'in_progress'}
      ]
    },
    {
      'items': [
        {'text': 'a', 'status': 'unknown'}
      ]
    },
    {'items': null},
    {
      'items': List.filled(201, {'text': 'a'})
    },
    {'unexpected': true},
  ];
  for (var i = 0; i < invalid.length; i++) {
    test('invalid update $i is atomic', () {
      final store = ChecklistStore();
      final value = plan(store);
      final before = store.toDict();
      expect(() => edit(store, value, invalid[i]), throwsArgumentError);
      expect(store.toDict(), before);
    });
  }

  test('item IDs cannot be changed or duplicated', () {
    final store = ChecklistStore();
    final value = plan(store);
    final items = value['items'] as List;
    final before = store.toDict();
    expect(
        () => edit(
            store,
            value,
            {
              'item_id': (items[0] as Map)['id'],
              'item': {'id': (items[1] as Map)['id']}
            },
            'update_item'),
        throwsArgumentError);
    expect(
        () => edit(store, value, {
              'items': [items[0], items[0]]
            }),
        throwsArgumentError);
    expect(store.toDict(), before);
  });

  test('derived status and atomic switch', () {
    final store = ChecklistStore();
    var value =
        store.execute('create', {'name': 'empty'}) as Map<String, Object?>;
    expect(value['status'], 'pending');
    expect((value['progress'] as Map)['fraction'], 0);
    value = edit(store, value, {
      'items': [
        {'text': 'a', 'status': 'blocked', 'notes': 'waiting'}
      ]
    });
    expect(value['status'], 'blocked');
    value = edit(store, value, {
      'items': [
        {'text': 'a', 'status': 'cancelled'}
      ]
    });
    expect(value['status'], 'cancelled');
    expect((value['progress'] as Map)['fraction'], 0);
    value = edit(store, value, {
      'items': [
        {'text': 'a', 'status': 'completed'},
        {'text': 'b', 'status': 'cancelled'}
      ]
    });
    expect(value['status'], 'completed');
    expect((value['progress'] as Map)['fraction'], 1);
    value = edit(store, value, {
      'items': [
        {'text': 'a', 'status': 'in_progress'},
        {'text': 'b'}
      ]
    });
    final items = value['items'] as List;
    final ids = items.map((x) => (x as Map)['id']).toList();
    value = edit(store, value, {
      'items': [
        {...(items[0] as Map), 'status': 'completed'},
        {...(items[1] as Map), 'status': 'in_progress'}
      ]
    });
    expect((value['items'] as List).map((x) => (x as Map)['id']).toList(), ids);
  });

  test('export/import is portable, atomic and isolated', () {
    final store = ChecklistStore();
    final value = plan(store);
    final document =
        jsonDecode(jsonEncode(store.execute('export', {'id': value['id']})))
            as Map<String, Object?>;
    final child = ChecklistStore();
    child.execute('import', {'document': document});
    edit(child, child.execute('get', {'id': value['id']}) as Map,
        {'name': 'child'});
    expect((store.execute('get', {'id': value['id']}) as Map)['name'], '出荷計画');
    ((document['checklists'] as List).first as Map)['name'] = 'mutated';
    expect((child.execute('get', {'id': value['id']}) as Map)['name'], 'child');
    final before = child.toDict();
    expect(() => child.execute('import', {'document': document}),
        throwsArgumentError);
    (document['checklists'] as List).add({});
    expect(() => child.execute('import', {'document': document}),
        throwsArgumentError);
    expect(child.toDict(), before);
    expect(WorkingState.fromDict({}).checklists.isEmpty, true);
  });

  test('projection modes, visibility and budget', () {
    final store = ChecklistStore();
    var value = plan(store);
    value = edit(store, value, {'context_mode': 'name'});
    expect(
        jsonDecode(store.render()), {'id': value['id'], 'name': value['name']});
    value = edit(store, value, {'context_mode': 'summary'});
    expect((jsonDecode(store.render()) as Map).containsKey('progress'), true);
    expect((jsonDecode(store.render()) as Map).containsKey('items'), false);
    value = edit(store, value, {'context_mode': 'full'});
    expect(((jsonDecode(store.render()) as Map)['items'] as List).length, 2);
    value = edit(store, value, {'include_in_context': false});
    expect(store.render(), '');
    expect((store.execute('list') as List).length, 1);
    edit(store, value, {
      'include_in_context': true,
      'items': List.filled(10, {'text': 'x' * 500, 'notes': 'y' * 2000})
    });
    expect(store.render(maxChars: 1000).length, lessThanOrEqualTo(1000));
    expect(store.render(maxChars: 1000), contains('progress'));
  });

  test('default tool serial edits and compression', () async {
    final steps = <Step>[];
    final llm = ScriptedLLM(steps);
    final session = Session(llm);
    expect(session.registry.get(tool)!.discovery.pinned, true);
    final value = await session
        .invoke(tool, {'action': 'create', 'name': 'durable'}) as Map;
    // ScriptedLLM copies its input, so use callbacks backed by the known ID
    // in a fresh session seeded with the same durable state.
    final nextLlm = ScriptedLLM([
      DecisionStep(Decision(calls: [
        ToolCall(name: tool, arguments: {
          'action': 'update',
          'id': value['id'],
          'expected_revision': 1,
          'name': 'first'
        }),
        ToolCall(name: tool, arguments: {
          'action': 'update',
          'id': value['id'],
          'expected_revision': 2,
          'name': 'second'
        }),
      ])),
      const TextStep('ok'),
      const TextStep('ok'),
    ]);
    final next =
        Session(nextLlm, seed: {'checklists': session.checklists.toDict()});
    await next.send('work');
    next.config.compression.summaryWindow = 0;
    next.config.compression.fullWindow = 0;
    next.config.compression.compressedWindow = 0;
    await next.send('continue');
    final messages = nextLlm.requests.last['messages'] as List<Message>;
    expect(
        messages.any((m) =>
            m.content.toString().contains('[Checklists') &&
            m.content.toString().contains('second')),
        true);
    expect(
        (next.checklists.execute('get', {'id': value['id']})
            as Map)['revision'],
        3);
  });

  test('policy can deny changes', () async {
    final session =
        Session(ScriptedLLM([]), policy: PolicyEngine(defaultDecision: 'deny'));
    await expectLater(session.invoke(tool, {'action': 'create', 'name': 'no'}),
        throwsStateError);
    expect(session.checklists.isEmpty, true);
  });

  test('restart recovers after snapshot gap and keeps deletion', () async {
    final dir = Directory.systemTemp.createTempSync('checklist-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cfg = Config.fromMap({
      'persistence': {'ledger_directory': dir.path}
    });
    final session = Session(ScriptedLLM([]), config: cfg);
    final initial = session.ledger.loadSnapshot(session.run.id)!;
    final value = await session.invoke(tool, {
      'action': 'create',
      'name': 'persist',
      'include_in_context': false
    }) as Map;
    session.ledger.saveSnapshot(initial);
    final restored =
        Session.resumeFromLedger(ScriptedLLM([]), session.run.id, config: cfg);
    expect(
        (restored.checklists.execute('get', {'id': value['id']})
            as Map)['include_in_context'],
        false);
    await restored.invoke(
        tool, {'action': 'delete', 'id': value['id'], 'expected_revision': 1});
    restored.ledger.saveSnapshot(initial);
    final again =
        Session.resumeFromLedger(ScriptedLLM([]), session.run.id, config: cfg);
    expect(again.checklists.isEmpty, true);
  });

  test('completed run retains plans on restart', () async {
    final dir = Directory.systemTemp.createTempSync('checklist-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cfg = Config.fromMap({
      'mode': 'job',
      'persistence': {'ledger_directory': dir.path}
    });
    final session = Session(
        ScriptedLLM([DecisionStep(ScriptedLLM.finish('done'))]),
        config: cfg);
    final value = await session
        .invoke(tool, {'action': 'create', 'name': 'retained'}) as Map;
    await session.runJob('finish');
    final restored =
        Session.resumeFromLedger(ScriptedLLM([]), session.run.id, config: cfg);
    expect(restored.run.state, 'COMPLETED');
    expect(
        (restored.checklists.execute('get', {'id': value['id']})
            as Map)['name'],
        'retained');
  });

  test("a spawned child keeps the parent's deny-list", () async {
    final seen = <List<Object?>>[];
    final session = Session(
      ScriptedLLM([]),
      registry: Registry(disabled: ['planning.checklist.manage']),
      builtins: ['meta', 'checklist', 'spawn'],
      policy: PolicyEngine(defaultDecision: 'allow'),
      spawnLlmFactory: (model) => ScriptedLLM([
        CallbackStep((messages, tools) {
          seen.add([for (final t in tools ?? const []) ((t as Map)['function'] as Map)['name']]);
          return ScriptedLLM.finish('done');
        }),
      ]),
    );
    expect(await session.invoke('meta.agent.spawn', {'task': 'work'}), 'done');
    expect(seen.single, contains('meta__tool__find'));
    expect(seen.single, isNot(contains('planning__checklist__manage')));
  });

  test('branch, rewind and spawn do not share plans', () async {
    String? id;
    final session = Session(
      ScriptedLLM([const TextStep('one'), const TextStep('two')]),
      policy: PolicyEngine(defaultDecision: 'allow'),
      spawnLlmFactory: (model) => ScriptedLLM([
        DecisionStep(ScriptedLLM.call(tool, arguments: {
          'action': 'update',
          'id': id,
          'expected_revision': 1,
          'name': 'delegated'
        })),
        DecisionStep(ScriptedLLM.finish('done')),
      ]),
    );
    final value = await session
        .invoke(tool, {'action': 'create', 'name': 'original'}) as Map;
    id = value['id'] as String;
    await session.send('first');
    final (child, _) = session.branch();
    await child.invoke(tool, {
      'action': 'update',
      'id': id,
      'expected_revision': 1,
      'name': 'branch'
    });
    expect((session.checklists.execute('get', {'id': id}) as Map)['name'],
        'original');
    await session.send('second');
    await session
        .invoke(tool, {'action': 'delete', 'id': id, 'expected_revision': 1});
    session.rewind(toTurn: 1);
    expect((session.checklists.execute('get', {'id': id}) as Map)['name'],
        'original');
    installBuiltins(session.registry, ['spawn']);
    final result = await session.invoke('meta.agent.spawn', {
      'task': 'work',
      'checklist_ids': [id]
    }) as Map;
    expect(result['result'], 'done');
    expect(
        (((result['checklists'] as Map)['checklists'] as List).first
            as Map)['name'],
        'delegated');
    expect((session.checklists.execute('get', {'id': id}) as Map)['name'],
        'original');
  });
}
