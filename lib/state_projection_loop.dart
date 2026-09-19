/// state-projection-loop — State-Projection Agent Loop.
///
/// Truth lives in the append-only Event Ledger, never in the model's
/// context; every turn renders a minimal disposable Projection derived from
/// it with fidelity-graded compression. The loop: Project → Decide →
/// Validate → Authorize → Execute → Record → Continue/Wait/Complete.
library;

export 'src/artifacts.dart' show ArtifactStore, ArtifactRecord, ref, isRef, refKey;
export 'src/builtin/builtin.dart' show installBuiltins, defaultBuiltins, builtinPacks;
export 'src/builtin/skills.dart' show skillCapability;
export 'src/builtin/toolkits.dart' show installToolkits;
export 'src/compaction.dart' show foldSchema, foldInstructions, parseFoldReply, applyFoldDelta;
export 'src/checklists.dart' show ChecklistStore, checklistStatuses, checklistContextModes;
export 'src/capability.dart'
    show
        Capability,
        CapabilityCard,
        CapabilitySpec,
        CapabilityDiscovery,
        CapabilityExecution,
        OutputPolicy,
        Effect,
        PlainHandler,
        CtxHandler,
        effectKinds,
        retrySafetyKinds;
export 'src/compression.dart'
    show compressText, summarizeText, contentHash, stripNoise, headTailTruncate;
export 'src/config.dart'
    show
        Config,
        ProjectionConfig,
        DiscoveryConfig,
        CompressionConfig,
        BudgetConfig,
        ArtifactsConfig,
        LimitsConfig,
        PersistenceConfig,
        CompactionConfig;
export 'src/context.dart' show ToolContext, TurnContext;
export 'src/discovery.dart' show ScoredTool, ToolSearch, tokenize;
export 'src/embeddings.dart' show EmbeddingBackend, HashingEmbedding, Vector, cosine;
export 'src/events.dart'
    show Event, EventLedger, InMemoryLedger, JsonlLedger, ObservedLedger, Snapshot, eventTypes, renderableTypes, eventToMessage;
export 'src/ids.dart' show newId, newUlid;
export 'src/llm.dart'
    show
        LLMAdapter,
        FallbackAdapter,
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
        KernelSection,
        TocSection,
        HistorySection,
        CandidatesSection,
        ChecklistSection,
        WorkingStateSection,
        buildDefaultSections,
        runtimeNotes;
export 'src/registry.dart' show Registry, ToolProvider;
export 'src/run.dart'
    show Run, RunStateError, Command, ApprovalRequest, Question, PendingQuestion, runStates, terminalStates, commandOutcomes;
export 'src/runtime.dart'
    show
        Runtime,
        ToolResult,
        ExecuteBatchResult,
        BudgetState,
        Hooks;
export 'src/json_schema.dart' show validateArgs, validateValue, applyDefaults;
export 'src/session.dart' show Session, ConcurrencyError;
export 'src/tokens.dart' show estimateTokens, estimateTextTokens, setEstimator, imageTokens;
export 'src/working_state.dart' show WorkingState, RecordedDecision, workingStateFields;

const String packageVersion = '0.5.0';
