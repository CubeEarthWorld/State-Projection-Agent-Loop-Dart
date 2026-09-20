/// Configuration.
///
/// Everything works with `Config()` untouched; features are enabled
/// additively.
library;

import 'serialization.dart' show deepCopy;

class ProjectionConfig {
  ProjectionConfig({
    List<String>? sections,
    this.windowTokens = 30000,
    this.reservedOutputTokens = 1024,
    this.providerOverheadTokens = 0,
    this.dedupeCandidateCardsAgainstSchemas = true,
  }) : sections =
            sections ?? ['kernel', 'toc', 'history', 'working_state', 'checklists', 'candidates'];

  // "toc" is a separate epoch-cached section: the kernel stays immutable
  // while the tool index may change mid-session.
  // "working_state" and "candidates" are both volatile (may change every
  // turn) and must stay last, in that order, after the append-only
  // conversation section.
  List<String> sections;
  int windowTokens;
  // Reserved so the model always has room to answer; counted against the
  // window budget alongside messages and native tool schemas.
  int reservedOutputTokens;
  // Provider-side fixed overhead not visible in the message list itself
  // (e.g. a vendor's per-request wrapping tokens); 0 is a safe default.
  int providerOverheadTokens;
  // When native tool schemas are sent to the provider, the candidates
  // section only needs the one-line signature, not the full card
  // description a second time.
  bool dedupeCandidateCardsAgainstSchemas;

  Map<String, Object?> toDict() => {
        'sections': sections,
        'window_tokens': windowTokens,
        'reserved_output_tokens': reservedOutputTokens,
        'provider_overhead_tokens': providerOverheadTokens,
        'dedupe_candidate_cards_against_schemas': dedupeCandidateCardsAgainstSchemas,
      };
}

class DiscoveryConfig {
  DiscoveryConfig({
    this.vector = 'auto', // "auto" | "on" | "off"
    this.k = 8,
    this.toc = true,
    this.activeTools = 48,
    List<String>? querySources,
  }) : querySources = querySources ??
            ['last_user_message', 'last_model_thought', 'goal_if_exists'];

  String vector;
  int k;
  bool toc;
  // Recently used non-pinned tools whose native schemas are re-sent each turn.
  int activeTools;
  List<String> querySources;

  Map<String, Object?> toDict() => {
        'vector': vector,
        'k': k,
        'toc': toc,
        'active_tools': activeTools,
        'query_sources': querySources,
      };
}

/// History renders in tiers measured from a verbatim point that moves in
/// steps (Session._stepTiers): the newest `fullWindow` messages are verbatim
/// once the tail grows past four times that; before the point, the next
/// `compressedWindow` messages are compressed (tool results masked to one
/// line unless they failed or report an error, assistant text head+tail),
/// the next `summaryWindow` are one-line summaries, older ones are dropped.
/// The user's own messages are never compressed or dropped.
class CompressionConfig {
  CompressionConfig({
    this.fullWindow = 6,
    this.compressedWindow = 24,
    this.summaryWindow = 60,
    this.compressedMaxLines = 80,
    this.observationMaxLines = 40,
  });

  int fullWindow;
  int compressedWindow;
  int summaryWindow;
  int compressedMaxLines;
  int observationMaxLines;

  Map<String, Object?> toDict() => {
        'full_window': fullWindow,
        'compressed_window': compressedWindow,
        'summary_window': summaryWindow,
        'compressed_max_lines': compressedMaxLines,
        'observation_max_lines': observationMaxLines,
      };
}

class BudgetConfig {
  BudgetConfig({
    this.maxSteps = 50,
    this.maxTokens,
    this.maxCost,
    this.maxSeconds,
    this.costPer1kInput = 0.0,
    this.costPer1kOutput = 0.0,
  });

  int? maxSteps; // null means no step limit, as for the other budget caps
  int? maxTokens;
  double? maxCost;
  double? maxSeconds;
  // Needed only when maxCost is set and the adapter reports usage.
  double costPer1kInput;
  double costPer1kOutput;

  Map<String, Object?> toDict() => {
        'max_steps': maxSteps,
        'max_tokens': maxTokens,
        'max_cost': maxCost,
        'max_seconds': maxSeconds,
        'cost_per_1k_input': costPer1kInput,
        'cost_per_1k_output': costPer1kOutput,
      };
}

class ArtifactsConfig {
  ArtifactsConfig({
    this.inlineThresholdTokens = 800,
    this.previewTokens = 120,
    this.directory,
  });

  int inlineThresholdTokens;
  int previewTokens;
  // When set, ArtifactStore persists large payloads to disk under this
  // directory (namespaced by run id) so a resumed run can recover them.
  String? directory;

  Map<String, Object?> toDict() => {
        'inline_threshold_tokens': inlineThresholdTokens,
        'preview_tokens': previewTokens,
        'directory': directory,
      };
}

class LimitsConfig {
  LimitsConfig({
    this.maxValidationRetries = 2,
    this.maxIdleTurns = 3,
    this.approvalExpiresS = 3600.0,
    this.maxRepeats = 3,
    this.repeatWindow = 8,
  });

  int maxValidationRetries;
  // Job mode: consecutive text-only (no tool call, no finish) turns
  // tolerated before the runtime nudges the model to call finish(result).
  int maxIdleTurns;
  // Default approval TTL; null means requests never expire on their own.
  double? approvalExpiresS;
  // Loop guard: an identical call repeated this many times inside the last
  // repeatWindow calls (all failing, or all returning the same result) is not
  // executed again; 0 disables the guard.
  int maxRepeats;
  int repeatWindow;

  Map<String, Object?> toDict() => {
        'max_validation_retries': maxValidationRetries,
        'max_idle_turns': maxIdleTurns,
        'approval_expires_s': approvalExpiresS,
        'max_repeats': maxRepeats,
        'repeat_window': repeatWindow,
      };
}

class PersistenceConfig {
  PersistenceConfig({
    this.ledgerDirectory,
  });

  // Directory for the JSONL event ledger + snapshots. null keeps the
  // ledger in-memory only (no cross-process resume).
  String? ledgerDirectory;

  Map<String, Object?> toDict() => {
        'ledger_directory': ledgerDirectory,
      };
}

class CompactionConfig {
  /// Fold when the prompt exceeds this share of the room the render has
  /// (window less reserved output), at the next step of the verbatim
  /// point. 0 turns the fold off; see docs/compression.md for the cost.
  CompactionConfig({this.triggerRatio = 0.75});

  // When the rendered prompt exceeds this fraction of the window, one extra
  // model call folds old history into the working state (see compaction.dart).
  // 0 disables compaction; deterministic compression always stays on.
  double triggerRatio;

  Map<String, Object?> toDict() => {'trigger_ratio': triggerRatio};
}

/// One model call: how long to wait, how often to retry a failed call (any
/// exception, including the timeout), and the pause between tries
/// (multiplied by the attempt number). Every failed attempt is a
/// `model_call_failed` ledger event; the last one also throws.
class ModelConfig {
  ModelConfig({this.timeoutS, this.retries = 0, this.backoffS = 1.0});

  double? timeoutS;
  int retries;
  double backoffS;

  Map<String, Object?> toDict() => {'timeout_s': timeoutS, 'retries': retries, 'backoff_s': backoffS};
}

class Config {
  Config({
    this.mode = 'chat', // "chat" | "job"
    this.resultSchema,
    ProjectionConfig? projection,
    DiscoveryConfig? discovery,
    CompressionConfig? compression,
    BudgetConfig? budget,
    ArtifactsConfig? artifacts,
    LimitsConfig? limits,
    PersistenceConfig? persistence,
    CompactionConfig? compaction,
    ModelConfig? model,
  })  : projection = projection ?? ProjectionConfig(),
        discovery = discovery ?? DiscoveryConfig(),
        compression = compression ?? CompressionConfig(),
        budget = budget ?? BudgetConfig(),
        artifacts = artifacts ?? ArtifactsConfig(),
        limits = limits ?? LimitsConfig(),
        persistence = persistence ?? PersistenceConfig(),
        compaction = compaction ?? CompactionConfig(),
        model = model ?? ModelConfig();

  String mode;
  // Job mode: JSON Schema finish(result) must satisfy; a failing result is
  // bounced back to the model like an argument error.
  Map<String, Object?>? resultSchema;
  final ProjectionConfig projection;
  final DiscoveryConfig discovery;
  final CompressionConfig compression;
  final BudgetConfig budget;
  final ArtifactsConfig artifacts;
  final LimitsConfig limits;
  final PersistenceConfig persistence;
  final CompactionConfig compaction;
  final ModelConfig model;

  factory Config.fromDict(Map<String, Object?> data) {
    final cfg = Config();
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      switch (key) {
        case 'mode':
          cfg.mode = value as String;
        case 'result_schema':
          cfg.resultSchema = (value as Map?)?.cast<String, Object?>();
        case 'compaction':
          _applySub(value, key, {
            'trigger_ratio': (v) => cfg.compaction.triggerRatio = (v as num).toDouble(),
          });
        case 'model':
          _applySub(value, key, {
            'timeout_s': (v) => cfg.model.timeoutS = (v as num?)?.toDouble(),
            'retries': (v) => cfg.model.retries = (v as num).toInt(),
            'backoff_s': (v) => cfg.model.backoffS = (v as num).toDouble(),
          });
        case 'projection':
          _applySub(value, key, {
            'sections': (v) => cfg.projection.sections = (v as List).cast<String>(),
            'window_tokens': (v) => cfg.projection.windowTokens = (v as num).toInt(),
            'reserved_output_tokens': (v) =>
                cfg.projection.reservedOutputTokens = (v as num).toInt(),
            'provider_overhead_tokens': (v) =>
                cfg.projection.providerOverheadTokens = (v as num).toInt(),
            'dedupe_candidate_cards_against_schemas': (v) =>
                cfg.projection.dedupeCandidateCardsAgainstSchemas = v as bool,
          });
        case 'discovery':
          _applySub(value, key, {
            'vector': (v) => cfg.discovery.vector = v as String,
            'k': (v) => cfg.discovery.k = (v as num).toInt(),
            'toc': (v) => cfg.discovery.toc = v as bool,
            'active_tools': (v) => cfg.discovery.activeTools = (v as num).toInt(),
            'query_sources': (v) =>
                cfg.discovery.querySources = (v as List).cast<String>(),
          });
        case 'compression':
          _applySub(value, key, {
            'full_window': (v) => cfg.compression.fullWindow = (v as num).toInt(),
            'compressed_window': (v) => cfg.compression.compressedWindow = (v as num).toInt(),
            'summary_window': (v) => cfg.compression.summaryWindow = (v as num).toInt(),
            'compressed_max_lines': (v) => cfg.compression.compressedMaxLines = (v as num).toInt(),
            'observation_max_lines': (v) => cfg.compression.observationMaxLines = (v as num).toInt(),
          });
        case 'budget':
          _applySub(value, key, {
            'max_steps': (v) => cfg.budget.maxSteps = (v as num?)?.toInt(),
            'max_tokens': (v) => cfg.budget.maxTokens = (v as num?)?.toInt(),
            'max_cost': (v) => cfg.budget.maxCost = (v as num?)?.toDouble(),
            'max_seconds': (v) => cfg.budget.maxSeconds = (v as num?)?.toDouble(),
            'cost_per_1k_input': (v) => cfg.budget.costPer1kInput = (v as num).toDouble(),
            'cost_per_1k_output': (v) => cfg.budget.costPer1kOutput = (v as num).toDouble(),
          });
        case 'artifacts':
          _applySub(value, key, {
            'inline_threshold_tokens': (v) =>
                cfg.artifacts.inlineThresholdTokens = (v as num).toInt(),
            'preview_tokens': (v) => cfg.artifacts.previewTokens = (v as num).toInt(),
            'directory': (v) => cfg.artifacts.directory = v as String?,
          });
        case 'limits':
          _applySub(value, key, {
            'max_validation_retries': (v) =>
                cfg.limits.maxValidationRetries = (v as num).toInt(),
            'max_idle_turns': (v) => cfg.limits.maxIdleTurns = (v as num).toInt(),
            'approval_expires_s': (v) =>
                cfg.limits.approvalExpiresS = (v as num?)?.toDouble(),
            'max_repeats': (v) => cfg.limits.maxRepeats = (v as num).toInt(),
            'repeat_window': (v) => cfg.limits.repeatWindow = (v as num).toInt(),
          });
        case 'persistence':
          _applySub(value, key, {
            'ledger_directory': (v) => cfg.persistence.ledgerDirectory = v as String?,
          });
        default:
          throw ArgumentError('Unknown config key: "$key"');
      }
    }
    return cfg;
  }

  static void _applySub(Object? value, String key,
      Map<String, void Function(Object?)> setters) {
    if (value is! Map) {
      throw ArgumentError('Config key "$key" expects a map');
    }
    for (final sub in value.entries) {
      final setter = setters[sub.key];
      if (setter == null) {
        throw ArgumentError('Unknown config key: $key.${sub.key}');
      }
      setter(sub.value);
    }
  }

  /// A deep, independent copy. The `deepCopy` is load-bearing: [fromDict]
  /// stores `.cast()` views over the map and lists it is handed, so a plain
  /// `fromDict(toDict())` would still alias this config's `sections`,
  /// `querySources` and `resultSchema`.
  Config clone() => Config.fromDict(deepCopy(toDict()));

  /// Key order follows the Python port's dataclass field order, so the two
  /// write the same bytes the day a config lands in a fixture or a ledger row.
  Map<String, Object?> toDict() => {
        'mode': mode,
        'result_schema': resultSchema,
        'projection': projection.toDict(),
        'discovery': discovery.toDict(),
        'compression': compression.toDict(),
        'budget': budget.toDict(),
        'artifacts': artifacts.toDict(),
        'limits': limits.toDict(),
        'persistence': persistence.toDict(),
        'compaction': compaction.toDict(),
        'model': model.toDict(),
      };
}
