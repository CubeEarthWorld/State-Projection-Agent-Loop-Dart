/// state-projection-loop — State-Projection Agent Loop.
///
/// Truth lives in the append-only Event Ledger, never in the model's
/// context; every turn renders a minimal disposable Projection derived from
/// it. The loop: Project → Decide → Validate → Plan Effects → Authorize →
/// Execute → Record → Continue/Wait/Complete.
library;

export 'src/artifacts.dart' show ArtifactStore, ArtifactRecord, ref, isRef, refKey;
export 'src/builtin/meta.dart' show ensureMetaTools, installSpawn;
export 'src/builtin/state.dart' show installState;
export 'src/capability.dart'
    show
        Capability,
        CapabilityCard,
        CapabilitySpec,
        CapabilityDiscovery,
        CapabilityExecution,
        ConcurrencyPolicy,
        OutputPolicy,
        Effect,
        ToolContext,
        PlainHandler,
        CtxHandler,
        effectKinds,
        retrySafetyKinds,
        concurrencyPolicies;
export 'src/compaction.dart' show Compactor, contractV2, deterministicFold, renderTranscript;
export 'src/config.dart'
    show
        Config,
        ProjectionConfig,
        DiscoveryConfig,
        CompactionConfig,
        BudgetConfig,
        ArtifactsConfig,
        LimitsConfig,
        PersistenceConfig;
export 'src/discovery.dart' show ScoredTool, ToolSearch, tokenize;
export 'src/embeddings.dart' show EmbeddingBackend, HashingEmbedding, Vector, cosine;
export 'src/events.dart' show Event, EventLedger, InMemoryLedger, JsonlLedger, Snapshot, eventTypes;
export 'src/ids.dart' show newId, newUlid, kindOf;
export 'src/llm.dart'
    show
        LLMAdapter,
        ScriptedLLM,
        Step,
        TextStep,
        DecisionStep,
        CallbackStep,
        extractFinish,
        parseTextToolCalls,
        finishName,
        finishSchema;
export 'src/messages.dart'
    show Decision, Message, ToolCall, Usage, kSystem, kUser, kAssistant, kObservation, newCallId;
export 'src/policy.dart'
    show
        PolicyEngine,
        PolicyDecision,
        Rule,
        ApprovalExpiry,
        layerOrder,
        decisions,
        scopes,
        presets,
        globMatch;
export 'src/projection.dart'
    show
        Projection,
        ProjectionError,
        Section,
        TurnContext,
        KernelSection,
        TocSection,
        ConversationSection,
        CandidatesSection,
        buildDefaultSections,
        cacheClasses;
export 'src/registry.dart' show Registry, ToolProvider;
export 'src/run.dart'
    show Run, RunStateError, Command, ApprovalRequest, runStates, terminalStates, commandOutcomes;
export 'src/runtime.dart'
    show
        Runtime,
        ToolResult,
        ExecuteBatchResult,
        BudgetState,
        validateArgs,
        applyDefaults,
        outcomes;
export 'src/session.dart' show Session, ConcurrencyError;
export 'src/tokens.dart' show estimateTokens, estimateTextTokens, setEstimator, resetEstimator;
export 'src/working_state.dart' show WorkingState, WorkingStateSection, RecordedDecision;

const String packageVersion = '0.2.0';
