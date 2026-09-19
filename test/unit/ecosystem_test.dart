// What connects a session to the world around it: cross-session memory,
// listing runs, SKILL.md directories, workspace instruction files.
// servers.
import 'dart:io';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:state_projection_loop/native.dart';
import 'package:test/test.dart';


Directory temp(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

List<String> observations(Session s) =>
    [for (final e in s.ledger.iterRun(s.run.id)) if (e.type == 'observation') e.data['text'] as String];

void main() {
  group('memory', () {
    test('notes saved in one session are found by the next', () async {
      final dir = temp('spal_mem_');
      final config = Config.fromDict({'persistence': {'ledger_directory': dir.path}});
      final first = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('memory.note.save',
              arguments: {'text': 'The user prefers tabs over spaces', 'tags': ['style']})),
          const TextStep('noted'),
        ]),
        builtins: ['memory'],
        config: config,
      );
      expect(await first.send('remember my style'), 'noted');
      expect(File('${dir.path}/memory.jsonl').existsSync(), isTrue);

      final second = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('memory.note.search', arguments: {'query': 'indentation style tabs'})),
          const TextStep('found'),
        ]),
        builtins: ['memory'],
        config: config,
      );
      await second.send('how do I indent?');
      expect(observations(second).first, allOf(contains('tabs over spaces'), contains('"style"')));
    });

    test('the default policy lets the model use memory', () {
      final session = Session(ScriptedLLM([]), builtins: ['memory']);
      final save = session.registry.get('memory.note.save')!;
      expect(session.policy.evaluate(save, {'text': 'x'}).decision, 'allow');
    });

    test('search ranks by shared terms then recency', () {
      final store = JsonlMemoryStore();
      store.save('deploy with make release', ['ops']);
      store.save('the release branch is called stable', ['git']);
      store.save('unrelated note', []);
      expect([for (final n in store.search('release branch', 5)) n.text],
          ['the release branch is called stable', 'deploy with make release']);
      expect(store.search('zzz', 5), isEmpty);
    });
  });

  group('list runs', () {
    test('a ledger lists its runs newest first', () async {
      final dir = temp('spal_runs_');
      final a = Session(ScriptedLLM([const TextStep('one')]),
          config: Config.fromDict({'persistence': {'ledger_directory': dir.path}}));
      await a.send('hi');
      final b = Session(ScriptedLLM([DecisionStep(ScriptedLLM.finish('done'))]),
          config: Config.fromDict({'mode': 'job', 'persistence': {'ledger_directory': dir.path}}));
      await b.runJob('task');
      final runs = JsonlLedger(dir.path).listRuns();
      expect([for (final r in runs) (r.runId, r.state)], [(b.run.id, 'COMPLETED'), (a.run.id, 'RUNNING')]);
      expect(runs.first.sessionId, b.sessionId);
      expect(InMemoryLedger().listRuns(), isEmpty);
    });
  });

  group('skill directories', () {
    test('SKILL.md files become skill capabilities', () {
      final dir = temp('spal_skills_');
      Directory('${dir.path}/deploy-service').createSync();
      File('${dir.path}/deploy-service/SKILL.md').writeAsStringSync(
          '---\nname: deploy-service\ndescription: "How to deploy the service"\n---\n1. run make release\n');
      Directory('${dir.path}/bare').createSync();
      File('${dir.path}/bare/SKILL.md').writeAsStringSync('Just the steps.');
      final skills = {for (final c in loadSkills(dir.path)) c.name: c};
      expect(skills.keys.toSet(), {'skill.bare.load', 'skill.deploy_service.load'});
      expect(skills['skill.deploy_service.load']!.card.summary, 'How to deploy the service');
      expect(skills['skill.deploy_service.load']!.execution.handler!(<String, Object?>{}), '1. run make release\n');
      expect(skills['skill.bare.load']!.execution.handler!(<String, Object?>{}), 'Just the steps.');
    });
  });

  group('instructions', () {
    test('instruction files up the tree are projected outermost first', () async {
      final dir = temp('spal_instr_');
      File('${dir.path}/AGENTS.md').writeAsStringSync('Repo rule: run the tests.');
      final nested = Directory('${dir.path}/pkg/sub')..createSync(recursive: true);
      File('${nested.path}/CLAUDE.md').writeAsStringSync('Package rule: no prints.');
      final text = InstructionsSection.load(nested.path);
      expect(text.indexOf('Repo rule'), lessThan(text.indexOf('Package rule')));
      expect(text, allOf(contains('[Instructions from '), contains('AGENTS.md]'), contains('CLAUDE.md]')));

      final llm = ScriptedLLM([const TextStep('ok')]);
      final session = Session(llm, sections: [InstructionsSection(nested.path)]);
      await session.send('hi');
      final first = (llm.requests.first['messages'] as List<Message>).first;
      expect(first.content.toString(), contains('Package rule: no prints.'));
    });

    test('no files means no message', () {
      expect(InstructionsSection(temp('spal_empty_').path).render(TurnContext(config: Config(), registry: Registry())),
          isEmpty);
    });
  });
}
