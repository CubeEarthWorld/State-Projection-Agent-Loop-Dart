// Discovery search engine: BM25, vector mixing, no_embed exclusion,
// category filters, epoch-driven reindexing.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

Registry makeRegistry() {
  final reg = Registry();
  reg.register(capabilityDict(
    'web.search',
    category: 'web/search',
    summary: 'ウェブを検索し上位結果を返す',
    tags: ['web', '検索'],
    embeddingText: '調べて 検索して 最新情報 ニュース 現在の 価格',
  ));
  reg.register(capabilityDict(
    'file.read',
    category: 'file',
    summary: 'ファイルを読み込む',
    tags: ['file'],
    embeddingText: 'ファイルを開く 読む 中身を見る open read file',
  ));
  reg.register(capabilityDict(
    'game.media.play_bgm',
    category: 'game/media',
    summary: 'BGMを再生する',
    tags: ['bgm', '音楽'],
    embeddingText: '音楽 BGM 曲を流す 雰囲気',
  ));
  reg.register(capabilityDict(
    'admin.secret_tool',
    category: 'admin',
    summary: 'hidden admin tool',
    noEmbed: true,
  ));
  return reg;
}

void main() {
  group('Lexical', () {
    test('japanese query hits embedding text', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final results = search.search('最新情報を検索して', k: 3);
      expect(results[0].tool.name, equals('web.search'));
    });

    test('english query', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final results = search.search('read a file', k: 3);
      expect(results[0].tool.name, equals('file.read'));
    });

    test('exact name query ranks first', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final results = search.search('play_bgm', k: 3);
      expect(results[0].tool.name, equals('game.media.play_bgm'));
    });

    test('empty query returns nothing', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      expect(search.search(''), equals([]));
      expect(search.search('   '), equals([]));
    });
  });

  group('Layers', () {
    test('layer2 excludes no_embed', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final names = search.search('hidden admin tool', layer: 2, k: 8).map((s) => s.tool.name);
      expect(names, isNot(contains('admin.secret_tool')));
    });

    test('layer3 reaches no_embed', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final names = search.search('hidden admin tool', layer: 3, k: 8).map((s) => s.tool.name);
      expect(names, contains('admin.secret_tool'));
    });

    test('exclude set', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final names =
          search.search('検索して', exclude: {'web.search'}, k: 8).map((s) => s.tool.name);
      expect(names, isNot(contains('web.search')));
    });
  });

  group('CategoryFilter', () {
    test('prefix match', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final results = search.search('検索', category: 'web', k: 8);
      expect(results.map((s) => s.tool.name).toSet(), equals({'web.search'}));
    });

    test('exact match', () {
      final search = ToolSearch(makeRegistry(), vector: 'off');
      final results = search.search('BGM 音楽', category: 'game/media', k: 8);
      expect(results.map((s) => s.tool.name).toList(), equals(['game.media.play_bgm']));
    });
  });

  group('VectorMixing', () {
    test('vector on requires backend', () {
      expect(
        () => ToolSearch(makeRegistry(), vector: 'on'),
        throwsA(isA<ArgumentError>().having(
            (e) => e.toString(), 'message', contains('requires an embedding backend'))),
      );
    });

    test('vector component present with backend', () {
      final search = ToolSearch(makeRegistry(), embedder: HashingEmbedding(), vector: 'on');
      final results = search.search('最新情報を検索して', k: 3);
      expect(results[0].tool.name, equals('web.search'));
      expect(results[0].components, contains('vector'));
      expect(results[0].components, contains('lexical'));
    });

    test('vector off ignores backend', () {
      final search = ToolSearch(makeRegistry(), embedder: HashingEmbedding(), vector: 'off');
      final results = search.search('検索して', k: 3);
      expect(results.every((s) => !s.components.containsKey('vector')), isTrue);
    });

    test('invalid vector mode', () {
      expect(
        () => ToolSearch(makeRegistry(), vector: 'maybe'),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', matches(RegExp('auto|on|off')))),
      );
    });
  });

  group('Reindexing', () {
    test('new tool found after epoch bump', () {
      final reg = makeRegistry();
      final search = ToolSearch(reg, vector: 'off');
      expect(
        search.search('翻訳 translate', k: 8).any((s) => s.tool.name == 'text.translate'),
        isFalse,
      );
      reg.register(capabilityDict(
        'text.translate',
        summary: 'テキストを翻訳する',
        embeddingText: '翻訳して 英語に 日本語に translate',
      ));
      final results = search.search('翻訳して translate', k: 8);
      expect(results[0].tool.name, equals('text.translate'));
    });
  });
}
