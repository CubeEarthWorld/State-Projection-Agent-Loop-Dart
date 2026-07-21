/// Configuration.
///
/// Everything works with `Config()` untouched; features are enabled
/// additively.
library;

class ProjectionConfig {
  ProjectionConfig({
    List<String>? sections,
    this.windowTokens = 30000,
    this.reservedOutputTokens = 1024,
    this.providerOverheadTokens = 0,
    this.dedupeCandidateCardsAgainstSchemas = true,
  }) : sections =
            sections ?? ['kernel', 'toc', 'history', 'working_state', 'candidates'];

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

  Map<String, Object?> toMap() => {
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
    List<String>? querySources,
  }) : querySources = querySources ??
            ['last_user_message', 'last_model_thought', 'goal_if_exists'];

  String vector;
  int k;
  bool toc;
  List<String> querySources;

  Map<String, Object?> toMap() => {
        'vector': vector,
        'k': k,
        'toc': toc,
        'query_sources': querySources,
      };
}

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

  Map<String, Object?> toMap() => {
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

  int maxSteps;
  int? maxTokens;
  double? maxCost;
  double? maxSeconds;
  // Needed only when maxCost is set and the adapter reports usage.
  double costPer1kInput;
  double costPer1kOutput;

  Map<String, Object?> toMap() => {
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

  Map<String, Object?> toMap() => {
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
  });

  int maxValidationRetries;
  // Job mode: consecutive text-only (no tool call, no finish) turns
  // tolerated before the runtime nudges the model to call finish(result).
  int maxIdleTurns;
  // Default approval TTL; null means requests never expire on their own.
  double? approvalExpiresS;

  Map<String, Object?> toMap() => {
        'max_validation_retries': maxValidationRetries,
        'max_idle_turns': maxIdleTurns,
        'approval_expires_s': approvalExpiresS,
      };
}

class PersistenceConfig {
  PersistenceConfig({
    this.ledgerDirectory,
    this.snapshotEveryNEvents = 20,
  });

  // Directory for the JSONL event ledger + snapshots. null keeps the
  // ledger in-memory only (no cross-process resume).
  String? ledgerDirectory;
  int snapshotEveryNEvents;

  Map<String, Object?> toMap() => {
        'ledger_directory': ledgerDirectory,
        'snapshot_every_n_events': snapshotEveryNEvents,
      };
}

class Config {
  Config({
    this.mode = 'chat', // "chat" | "job"
    ProjectionConfig? projection,
    DiscoveryConfig? discovery,
    CompressionConfig? compression,
    BudgetConfig? budget,
    ArtifactsConfig? artifacts,
    LimitsConfig? limits,
    PersistenceConfig? persistence,
  })  : projection = projection ?? ProjectionConfig(),
        discovery = discovery ?? DiscoveryConfig(),
        compression = compression ?? CompressionConfig(),
        budget = budget ?? BudgetConfig(),
        artifacts = artifacts ?? ArtifactsConfig(),
        limits = limits ?? LimitsConfig(),
        persistence = persistence ?? PersistenceConfig();

  String mode;
  final ProjectionConfig projection;
  final DiscoveryConfig discovery;
  final CompressionConfig compression;
  final BudgetConfig budget;
  final ArtifactsConfig artifacts;
  final LimitsConfig limits;
  final PersistenceConfig persistence;

  static const Set<String> _topLevelKeys = {
    'mode',
    'projection',
    'discovery',
    'compression',
    'budget',
    'artifacts',
    'limits',
    'persistence',
  };

  factory Config.fromMap(Map<String, Object?> data) {
    final cfg = Config();
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      if (!_topLevelKeys.contains(key)) {
        throw ArgumentError('Unknown config key: "$key"');
      }
      switch (key) {
        case 'mode':
          cfg.mode = value as String;
        case 'projection':
          _applySub(cfg.projection, value, key, {
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
          _applySub(cfg.discovery, value, key, {
            'vector': (v) => cfg.discovery.vector = v as String,
            'k': (v) => cfg.discovery.k = (v as num).toInt(),
            'toc': (v) => cfg.discovery.toc = v as bool,
            'query_sources': (v) =>
                cfg.discovery.querySources = (v as List).cast<String>(),
          });
        case 'compression':
          _applySub(cfg.compression, value, key, {
            'full_window': (v) => cfg.compression.fullWindow = (v as num).toInt(),
            'compressed_window': (v) => cfg.compression.compressedWindow = (v as num).toInt(),
            'summary_window': (v) => cfg.compression.summaryWindow = (v as num).toInt(),
            'compressed_max_lines': (v) => cfg.compression.compressedMaxLines = (v as num).toInt(),
            'observation_max_lines': (v) => cfg.compression.observationMaxLines = (v as num).toInt(),
          });
        case 'budget':
          _applySub(cfg.budget, value, key, {
            'max_steps': (v) => cfg.budget.maxSteps = (v as num).toInt(),
            'max_tokens': (v) => cfg.budget.maxTokens = (v as num?)?.toInt(),
            'max_cost': (v) => cfg.budget.maxCost = (v as num?)?.toDouble(),
            'max_seconds': (v) => cfg.budget.maxSeconds = (v as num?)?.toDouble(),
            'cost_per_1k_input': (v) => cfg.budget.costPer1kInput = (v as num).toDouble(),
            'cost_per_1k_output': (v) => cfg.budget.costPer1kOutput = (v as num).toDouble(),
          });
        case 'artifacts':
          _applySub(cfg.artifacts, value, key, {
            'inline_threshold_tokens': (v) =>
                cfg.artifacts.inlineThresholdTokens = (v as num).toInt(),
            'preview_tokens': (v) => cfg.artifacts.previewTokens = (v as num).toInt(),
            'directory': (v) => cfg.artifacts.directory = v as String?,
          });
        case 'limits':
          _applySub(cfg.limits, value, key, {
            'max_validation_retries': (v) =>
                cfg.limits.maxValidationRetries = (v as num).toInt(),
            'max_idle_turns': (v) => cfg.limits.maxIdleTurns = (v as num).toInt(),
            'approval_expires_s': (v) =>
                cfg.limits.approvalExpiresS = (v as num?)?.toDouble(),
          });
        case 'persistence':
          _applySub(cfg.persistence, value, key, {
            'ledger_directory': (v) => cfg.persistence.ledgerDirectory = v as String?,
            'snapshot_every_n_events': (v) =>
                cfg.persistence.snapshotEveryNEvents = (v as num).toInt(),
          });
      }
    }
    return cfg;
  }

  static void _applySub(Object current, Object? value, String key,
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

  Map<String, Object?> toMap() => {
        'mode': mode,
        'projection': projection.toMap(),
        'discovery': discovery.toMap(),
        'compression': compression.toMap(),
        'budget': budget.toMap(),
        'artifacts': artifacts.toMap(),
        'limits': limits.toMap(),
        'persistence': persistence.toMap(),
      };
}
