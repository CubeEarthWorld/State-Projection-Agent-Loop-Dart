/// Tool discovery search engine, shared by layer 2 (auto candidates) and
/// layer 3 (find_tools).
///
/// Pure computation: no LLM is ever involved. Scoring mixes vector
/// similarity, BM25 lexical match, and tag/name match. With vectors
/// disabled or unavailable, weights renormalize over the remaining
/// components.
library;

import 'dart:math' as math;

import 'capability.dart';
import 'embeddings.dart';
import 'registry.dart';

final RegExp _asciiWord = RegExp(r'[a-z0-9_]+');

/// ASCII words + CJK bigrams (unigram only for isolated single chars).
///
/// Single-char CJK grams are deliberately excluded from longer runs:
/// particles like 「の」「ー」 match almost everything and turn BM25 into
/// noise (found by the embeddinggemma integration test).
List<String> tokenize(String? input) {
  final text = (input ?? '').toLowerCase();
  final tokens = <String>[..._asciiWord.allMatches(text).map((m) => m.group(0)!)];
  final cjkRun = <String>[];

  void flush() {
    if (cjkRun.isEmpty) return;
    if (cjkRun.length == 1) {
      tokens.add(cjkRun[0]);
    } else {
      for (var i = 0; i < cjkRun.length - 1; i++) {
        tokens.add(cjkRun[i] + cjkRun[i + 1]);
      }
    }
    cjkRun.clear();
  }

  for (final rune in text.runes) {
    final o = rune;
    if ((o >= 0x3000 && o <= 0x9FFF) ||
        (o >= 0xF900 && o <= 0xFAFF) ||
        (o >= 0xAC00 && o <= 0xD7AF)) {
      cjkRun.add(String.fromCharCode(o));
    } else {
      flush();
    }
  }
  flush();
  return tokens;
}

class ScoredTool {
  ScoredTool({required this.tool, required this.score, Map<String, double>? components})
      : components = components ?? <String, double>{};

  final Capability tool;
  final double score;
  final Map<String, double> components;
}

/// Mixed vector + lexical + tag scoring over the registry.
///
/// The index rebuilds lazily whenever the registry epoch changes, so
/// provider-driven tool changes are picked up automatically.
class ToolSearch {
  ToolSearch(
    this.registry, {
    EmbeddingBackend? embedder,
    String vector = 'auto',
    Map<String, double>? weights,
  }) : weights = weights ?? Map<String, double>.from(defaultWeights) {
    if (!['auto', 'on', 'off'].contains(vector)) {
      throw ArgumentError('vector must be auto|on|off, got "$vector"');
    }
    if (vector == 'on' && embedder == null) {
      throw ArgumentError("discovery.vector='on' requires an embedding backend");
    }
    this.embedder = vector != 'off' ? embedder : null;
  }

  static const Map<String, double> defaultWeights = {
    'vector': 0.55,
    'lexical': 0.30,
    'tags': 0.15,
  };

  final Registry registry;
  late final EmbeddingBackend? embedder;
  final Map<String, double> weights;

  int _epoch = -1;
  Map<String, List<String>> _docTokens = {};
  Map<String, int> _df = {};
  double _avgdl = 1.0;
  Map<String, Vector> _vectors = {};
  Map<String, String> _sources = {}; // the text each vector was made from

  // -- index --------------------------------------------------------------

  String _docText(Capability tool) {
    final parts = [
      tool.name.replaceAll('_', ' '),
      tool.name,
      tool.category,
      tool.card.summary,
      tool.card.tags.join(' '),
      tool.discovery.embeddingText,
      tool.spec.description,
    ];
    return parts.where((p) => p.isNotEmpty).join(' ');
  }

  void _ensureIndex() {
    if (_epoch == registry.epoch) return;
    _docTokens = {
      for (final t in registry.capabilities) t.name: tokenize(_docText(t)),
    };
    _df = {};
    for (final toks in _docTokens.values) {
      for (final tok in toks.toSet()) {
        _df[tok] = (_df[tok] ?? 0) + 1;
      }
    }
    final lengths = _docTokens.values.map((t) => t.length).toList();
    _avgdl = lengths.isEmpty
        ? 1.0
        : lengths.reduce((a, b) => a + b) / lengths.length;
    // Embed only what changed: every registry mutation bumps the epoch (a
    // lone disable() included), and re-embedding all N tools for one is a
    // whole round-trip to the backend. Indexed, not zipped: a backend
    // returning fewer vectors than asked for must fail loudly, not silently
    // drop the tail from semantic search.
    final emb = embedder;
    final sources = <String, String>{
      if (emb != null)
        for (final t in registry.capabilities)
          if (!t.discovery.noEmbed) t.name: t.embeddingSource(),
    };
    final stale = [for (final e in sources.entries) if (_sources[e.key] != e.value) e.key];
    final vecs = stale.isEmpty ? <Vector>[] : emb!.embedDocuments([for (final n in stale) sources[n]!]);
    final fresh = {for (var i = 0; i < stale.length; i++) stale[i]: vecs[i]};
    _vectors = {for (final n in sources.keys) n: fresh[n] ?? _vectors[n]!};
    _sources = sources;
    _epoch = registry.epoch;
  }

  // -- scoring ------------------------------------------------------------

  double _bm25(List<String> queryTokens, String name,
      {double k1 = 1.5, double b = 0.75}) {
    final toks = _docTokens[name] ?? const <String>[];
    if (toks.isEmpty) return 0.0;
    final nDocs = math.max(1, _docTokens.length);
    final counts = <String, int>{};
    for (final t in toks) {
      counts[t] = (counts[t] ?? 0) + 1;
    }
    var score = 0.0;
    for (final qt in queryTokens) {
      final tf = counts[qt] ?? 0;
      if (tf == 0) continue;
      final df = _df[qt] ?? 0;
      final idf = math.log(1 + (nDocs - df + 0.5) / (df + 0.5));
      final denom = tf + k1 * (1 - b + b * toks.length / _avgdl);
      score += idf * (tf * (k1 + 1)) / denom;
    }
    return score;
  }

  double _tagScore(String query, List<String> queryTokens, Capability tool) {
    final q = query.toLowerCase();
    var score = 0.0;
    if (q.contains(tool.name.toLowerCase())) {
      score += 1.0;
    }
    final qset = queryTokens.toSet();
    final tags = tool.card.tags.map((t) => t.toLowerCase()).toSet();
    if (tags.isNotEmpty) {
      final overlap = tags.where((t) => qset.contains(t) || q.contains(t)).length;
      score += math.min(1.0, overlap / math.max(1, tags.length) * 1.5);
    }
    return math.min(score, 1.0);
  }

  /// Rank tools for a natural-language query.
  ///
  /// `layer=2` (auto candidates) excludes `noEmbed` tools; `layer=3`
  /// (find_tools) searches everything.
  List<ScoredTool> search(
    String query, {
    String? category,
    int k = 8,
    int layer = 3,
    Set<String>? exclude,
  }) {
    _ensureIndex();
    final excludeSet = exclude ?? <String>{};
    final tools = <Capability>[];
    for (final t in registry.capabilities) {
      if (excludeSet.contains(t.name)) continue;
      if (layer == 2 && t.discovery.noEmbed) continue;
      if (category != null) {
        final cat = t.category.isEmpty ? 'misc' : t.category;
        // Strip any trailing '/' and '*' — "file*", "file/", "a/**" and
        // "a/*" all name the same category, as Python's rstrip("/*") does.
        final norm = category.replaceAll(RegExp(r'[/*]+$'), '');
        if (!(cat == norm || cat.startsWith('$norm/'))) continue;
      }
      tools.add(t);
    }
    if (tools.isEmpty || query.trim().isEmpty) return [];

    final queryTokens = tokenize(query);
    // absolute squash, not max-normalization: a tiny incidental match must
    // stay tiny instead of being amplified to full scale
    final lexical = {
      for (final t in tools) t.name: _bm25(queryTokens, t.name),
    };

    Vector? qvec;
    final emb = embedder;
    if (emb != null && _vectors.isNotEmpty) {
      qvec = emb.embedQuery(query);
    }

    final results = <ScoredTool>[];
    for (final t in tools) {
      final components = <String, double>{};
      final localWeights = <String, double>{};
      if (qvec != null && _vectors.containsKey(t.name)) {
        components['vector'] = (cosine(qvec, _vectors[t.name]!) + 1.0) / 2.0;
        localWeights['vector'] = weights['vector']!;
      }
      final lex = lexical[t.name]!;
      components['lexical'] = lex / (lex + 1.0);
      localWeights['lexical'] = weights['lexical']!;
      components['tags'] = _tagScore(query, queryTokens, t);
      localWeights['tags'] = weights['tags']!;
      final wsum = localWeights.values.fold(0.0, (a, b) => a + b);
      final denom = wsum == 0 ? 1.0 : wsum;
      var score = 0.0;
      for (final key in components.keys) {
        score += components[key]! * (localWeights[key] ?? 0.0);
      }
      score /= denom;
      if (score > 0) {
        results.add(ScoredTool(tool: t, score: score, components: components));
      }
    }
    // List.sort is not stable in Dart, and these candidates are projected
    // every turn: without a tie-break, two tools with the same score could
    // swap places between turns and change the prompt for no reason. The
    // registry's own order breaks the tie, matching Python's stable sort.
    final order = {for (var i = 0; i < results.length; i++) results[i].tool.name: i};
    results.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : order[a.tool.name]!.compareTo(order[b.tool.name]!);
    });
    return results.take(k).toList();
  }
}
