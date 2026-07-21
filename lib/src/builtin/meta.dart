/// Resident meta capabilities: `find_tools`, `peek`, and `search_history`
/// are always present; `spawn` is opt-in via [installSpawn].
///
/// There is no `done` capability anymore: completion is `Decision.finish`,
/// a property of the model's response handled directly by the session
/// loop, not something routed through the runtime like any other call. See
/// `llm.dart`'s `extractFinish`.
library;

import 'dart:async';

import '../artifacts.dart' show ArtifactStore, isRef, refKey;
import '../capability.dart';
import '../config.dart';
import '../discovery.dart' show ToolSearch;
import '../events.dart' show EventLedger;
import '../registry.dart';
import '../run.dart' show Run;
import '../session.dart';

final Map<String, Object?> findToolsDef = {
  'name': 'meta.tool.find',
  'category': 'meta',
  'card': {
    'summary': 'ツール台帳を自然文で検索し、該当ツールのカード一覧を返す',
    'signature': 'find_tools(query: str, category: str | None = None, k: int = 8) -> list[ToolCard]',
    'tags': ['meta', '検索'],
  },
  'spec': {
    'description':
        'Search the capability registry with a natural-language query and return matching cards.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'やりたいことを自然文で'},
        'category': {
          'type': ['string', 'null'],
          'description': '目次のカテゴリで絞り込み',
        },
        'k': {'type': 'integer', 'default': 8, 'minimum': 1, 'maximum': 50},
      },
      'required': ['query'],
    },
    'usage_notes': '自動候補に必要なツールが見当たらない時に使う。目次のカテゴリ名で絞れる。',
  },
  'discovery': {'pinned': true, 'no_embed': true},
  'execution': {'timeout_s': 10, 'retry_safety': 'pure'},
  'effects': [
    {'kind': 'none'},
  ],
};

Object? _findTools(ToolContext ctx, Map<String, Object?> args) {
  final query = args['query'] as String;
  final category = args['category'] as String?;
  final k = (args['k'] as num?)?.toInt() ?? 8;
  final search = ctx.search as ToolSearch;
  final results = search.search(query, category: category, k: k, layer: 3);
  if (results.isEmpty) {
    final toc = (ctx.registry as Registry).tocText();
    return 'No tools matched "$query". Categories: ${toc.isNotEmpty ? toc : '(none)'}';
  }
  final session = ctx.session;
  if (session is Session) {
    session.activateTools([for (final s in results) s.tool.name]);
  }
  return [
    for (final s in results)
      {
        'name': s.tool.name,
        'category': s.tool.category,
        'card': s.tool.cardText(),
        'score': (s.score * 1000).round() / 1000,
      },
  ];
}

final Map<String, Object?> peekDef = {
  'name': 'meta.artifact.peek',
  'category': 'meta',
  'card': {
    'summary': 'アーティファクト参照の中身を部分閲覧する',
    'signature':
        'peek(artifact: {"\$artifact": str}, query: str | null = None, range: str | null = None) -> str',
    'tags': ['meta', '参照'],
  },
  'spec': {
    'description':
        'Partially inspect the value stored behind an artifact reference ({"\$artifact": "..."}).',
    'parameters': {
      'type': 'object',
      'properties': {
        'artifact': {'type': 'object', 'description': '構造化参照 {"\$artifact": "art_..."}'},
        'query': {
          'type': ['string', 'null'],
          'description': '中身から探したい内容',
        },
        'range': {
          'type': ['string', 'null'],
          'description': "行範囲(例 '10-40')やキーパス(例 'items[0].name')",
        },
      },
      'required': ['artifact'],
    },
    'usage_notes': 'プレビューで足りない時のみ使う。全量展開は避け、queryかrangeで絞る。',
  },
  'discovery': {'pinned': true, 'no_embed': true},
  'execution': {'timeout_s': 10, 'retry_safety': 'pure', 'resolve_handles': false},
  'effects': [
    {'kind': 'none'},
  ],
};

String _peek(ToolContext ctx, Map<String, Object?> args) {
  final artifact = args['artifact'];
  final query = args['query'] as String?;
  final range = args['range'] as String?;
  if (!isRef(artifact)) {
    return 'Error: $artifact is not a valid artifact reference; expected {"\$artifact": "<id>"}';
  }
  final store = ctx.store as ArtifactStore;
  return store.peek((artifact as Map)[refKey] as String, query: query, range: range);
}

final Map<String, Object?> searchHistoryDef = {
  'name': 'meta.history.search',
  'category': 'meta',
  'card': {
    'summary': '折り畳まれた過去の会話をイベント台帳から検索する',
    'signature': 'search_history(query: str, k: int = 10) -> list[str]',
    'tags': ['meta', '検索', '履歴'],
  },
  'spec': {
    'description':
        'Search the append-only event ledger for this run, including messages folded out of the '
            'live conversation by compaction. Use when working_state doesn\'t have enough detail.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'k': {'type': 'integer', 'default': 10, 'minimum': 1, 'maximum': 50},
      },
      'required': ['query'],
    },
  },
  'discovery': {'pinned': true, 'no_embed': true},
  'execution': {'timeout_s': 10, 'retry_safety': 'pure'},
  'effects': [
    {'kind': 'none'},
  ],
};

Object? _searchHistory(ToolContext ctx, Map<String, Object?> args) {
  final query = args['query'] as String;
  final k = (args['k'] as num?)?.toInt() ?? 10;
  final ledger = ctx.ledger as EventLedger?;
  final run = ctx.run as Run?;
  if (ledger == null || run == null) {
    return 'History search is unavailable (no ledger configured for this session).';
  }
  final q = query.toLowerCase();
  final hits = <String>[];
  for (final event in ledger.iterRun(run.id)) {
    final blob = event.data.toString();
    if (blob.toLowerCase().contains(q)) {
      final preview = blob.length > 300 ? blob.substring(0, 300) : blob;
      hits.add('[${event.sequence}] ${event.type}: $preview');
      if (hits.length >= k) break;
    }
  }
  return hits.isNotEmpty ? hits : ['No ledger events matched "$query".'];
}

final Map<String, Object?> spawnDef = {
  'name': 'meta.agent.spawn',
  'category': 'meta',
  'card': {
    'summary': 'サブエージェントを起動しタスクを委任、結果アーティファクトを受け取る',
    'signature':
        'spawn(task: str, kernel: str | None = None, tool_scope: list | None = None, model: str | None = None, max_steps: int = 15) -> Any',
    'tags': ['meta', 'swarm', 'サブエージェント'],
  },
  'spec': {
    'description':
        'Run a sub-agent with its own independent context on the given task. Parent and child share '
            'ONLY the task string (input) and the result (output); artifacts must be explicitly moved.',
    'parameters': {
      'type': 'object',
      'properties': {
        'task': {'type': 'string', 'description': '委任するタスクの完全な記述(子は親の文脈を一切見られない)'},
        'kernel': {
          'type': ['string', 'null'],
          'description': '子のシステムプロンプト(省略時は汎用ジョブカーネル)',
        },
        'tool_scope': {
          'type': ['array', 'null'],
          'items': {'type': 'string'},
          'description': "子に許可するツール名/カテゴリ(例 ['web/*','file'])。省略時は親と同じ台帳",
        },
        'model': {
          'type': ['string', 'null'],
          'description': '子で使うモデル名(spawn_llm_factory が必要)',
        },
        'max_steps': {'type': 'integer', 'default': 15, 'minimum': 1, 'maximum': 100},
      },
      'required': ['task'],
    },
    'usage_notes': '自己完結したタスクの記述を渡すこと。親の会話内容は共有されない。',
  },
  'discovery': {'pinned': true, 'no_embed': true},
  'execution': {'timeout_s': 600, 'retry_safety': 'never_retry'},
  'effects': [
    {'kind': 'external', 'resource': 'subagent:*'},
  ],
};

Future<Object?> _spawn(ToolContext ctx, Map<String, Object?> args) async {
  final task = args['task'] as String;
  final kernel = args['kernel'] as String?;
  final toolScope = (args['tool_scope'] as List?)?.cast<String>();
  final model = args['model'] as String?;
  final maxSteps = (args['max_steps'] as num?)?.toInt() ?? 15;

  final parent = ctx.session;
  if (parent is! Session) {
    throw StateError('spawn requires a session context');
  }
  if (model != null && parent.spawnLlmFactory == null) {
    throw StateError('spawn(model=...) requires Session(spawnLlmFactory: ...)');
  }
  final llm = parent.spawnLlmFactory != null ? parent.spawnLlmFactory!(model) : parent.llm;

  Registry childRegistry;
  if (toolScope != null && toolScope.isNotEmpty) {
    childRegistry = parent.registry.subset(toolScope);
  } else {
    childRegistry = Registry();
    for (final cap in parent.registry.all_) {
      if (cap.name != 'meta.agent.spawn') {
        // no recursive swarm by default
        childRegistry.register(cap, replace: true);
      }
    }
  }

  final childConfig = Config.fromMap(parent.config.toMap());
  childConfig.mode = 'job';
  childConfig.budget.maxSteps = maxSteps;
  childConfig.persistence.ledgerDirectory = null; // child ledger is not persisted independently

  final child = Session(
    llm,
    kernel: kernel ?? 'You are a focused sub-agent. Complete the task, then call finish(result) with the outcome.',
    config: childConfig,
    registry: childRegistry,
    embedder: parent.search.embedder,
    policy: parent.policy,
  );
  return await child.runJob(task);
}

/// Register the resident meta capabilities if absent.
void ensureMetaTools(Registry registry) {
  if (!registry.contains('meta.tool.find')) {
    registry.register(findToolsDef, handler: _findTools, wantsCtx: true);
  }
  if (!registry.contains('meta.artifact.peek')) {
    registry.register(peekDef, handler: _peek, wantsCtx: true);
  }
  if (!registry.contains('meta.history.search')) {
    registry.register(searchHistoryDef, handler: _searchHistory, wantsCtx: true);
  }
}

/// Opt-in sub-agent capability for swarm-style setups.
void installSpawn(Registry registry) {
  if (!registry.contains('meta.agent.spawn')) {
    registry.register(spawnDef, handler: _spawn, wantsCtx: true);
  }
}
