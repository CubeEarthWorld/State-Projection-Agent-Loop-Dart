/// Capabilities: versioned execution contracts.
///
/// A Capability is not just a function signature — it is a full contract the
/// runtime and policy engine can reason about *without* running the handler:
/// what it touches ([Effect]s), whether it is safe to retry after a timeout
/// (`retrySafety`), and whether it may run alongside other calls
/// (`concurrency`). The LLM only ever sees the projected card/spec text; it
/// never gets to assert any of these properties itself.
///
/// Naming: capabilities live in a dotted namespace 2-5 levels deep, mirroring
/// a stable service/resource/operation shape rather than an org chart, e.g.
/// `filesystem.file.read@1`, `github.pull_request.create@1`. `name` is the
/// dotted path; `version` is a plain integer. The qualified id
/// (`name@version`) is what the registry indexes on, so two versions of the
/// same capability can coexist during a rollout.
///
/// Unlike the Python original, this port has no runtime signature/docstring
/// introspection (no `inspect`/`typing` equivalent in Dart): capabilities
/// are always built via [Capability.fromMap] with an explicit handler and an
/// explicit `wantsCtx` flag, rather than derived from a decorated function.
library;

import 'dart:async';
import 'dart:convert';

const List<String> effectKinds = ['none', 'read', 'write', 'external'];
const List<String> retrySafetyKinds = [
  'pure',
  'idempotent',
  'check_then_retry',
  'never_retry',
];
const List<String> concurrencyPolicies = [
  'parallel_safe',
  'sequential_only',
  'exclusive_resource',
];

/// Handler signature for capabilities that do not need [ToolContext]. May
/// be sync or async (return a bare value or a [Future]).
typedef PlainHandler = FutureOr<Object?> Function(Map<String, Object?> args);

/// Handler signature for capabilities that declare `wantsCtx: true`; `ctx`
/// is injected by the runtime and excluded from the JSON schema. May be
/// sync or async.
typedef CtxHandler = FutureOr<Object?> Function(
    ToolContext ctx, Map<String, Object?> args);

/// One declared side effect: what kind, and which resource it touches.
///
/// `resource` is a free-form pattern the policy engine matches against rules
/// (e.g. `workspace:*`, `network:api.github.com`, `secrets:*`). Declaration
/// is self-reported by the capability author; it is the *planned* effect,
/// not a runtime guarantee.
class Effect {
  Effect({required this.kind, this.resource = '*'}) {
    if (!effectKinds.contains(kind)) {
      throw ArgumentError(
          'Effect.kind must be one of $effectKinds, got "$kind"');
    }
  }

  final String kind;
  final String resource;
}

/// Runtime services available to capability handlers.
///
/// A handler opts in by declaring `wantsCtx: true` on its [Capability];
/// `commandId` is stable across retries of the *same* logical attempt and is
/// the correct idempotency key to hand to an external API.
class ToolContext {
  ToolContext({
    this.session,
    this.registry,
    this.store,
    this.workingState,
    this.config,
    this.search,
    this.ledger,
    this.run,
    this.commandId = '',
  });

  final Object? session;
  final Object? registry;
  final Object? store;
  final Object? workingState;
  final Object? config;
  final Object? search;
  final Object? ledger;
  final Object? run;
  final String commandId;

  ToolContext copyWith({String? commandId}) => ToolContext(
        session: session,
        registry: registry,
        store: store,
        workingState: workingState,
        config: config,
        search: search,
        ledger: ledger,
        run: run,
        commandId: commandId ?? this.commandId,
      );
}

class CapabilityCard {
  CapabilityCard({this.summary = '', this.signature = '', List<String>? tags})
      : tags = tags ?? <String>[];

  String summary;
  String signature;
  final List<String> tags;
}

class CapabilitySpec {
  CapabilitySpec({
    this.description = '',
    Map<String, Object?>? parameters,
    this.returns,
    this.usageNotes = '',
    List<Map<String, Object?>>? examples,
  })  : parameters = parameters ?? {'type': 'object', 'properties': {}},
        examples = examples ?? <Map<String, Object?>>[];

  final String description;
  final Map<String, Object?> parameters;
  final Map<String, Object?>? returns;
  final String usageNotes;
  final List<Map<String, Object?>> examples;
}

class CapabilityDiscovery {
  CapabilityDiscovery({
    this.pinned = false,
    this.requireSpec = false,
    this.embeddingText = '',
    this.noEmbed = false,
  });

  final bool pinned;
  final bool requireSpec;
  final String embeddingText;
  final bool noEmbed;
}

class OutputPolicy {
  OutputPolicy({
    this.maxInlineTokens, // null -> config.artifacts.inlineThresholdTokens
    this.overflow = 'artifact', // "artifact" | "truncate"
    this.preview = 'head', // "head" | "tail"
  });

  final int? maxInlineTokens;
  final String overflow;
  final String preview;
}

class ConcurrencyPolicy {
  ConcurrencyPolicy({this.mode = 'sequential_only', this.resourceKey}) {
    if (!concurrencyPolicies.contains(mode)) {
      throw ArgumentError(
          'concurrency.mode must be one of $concurrencyPolicies, got "$mode"');
    }
    if (mode == 'exclusive_resource' &&
        (resourceKey == null || resourceKey!.isEmpty)) {
      throw ArgumentError(
          "concurrency.mode='exclusive_resource' requires resourceKey");
    }
  }

  final String mode;
  final String? resourceKey;
}

class CapabilityExecution {
  CapabilityExecution({
    this.handler,
    this.handlerRef = '',
    this.timeoutS = 30.0,
    this.retries = 0,
    this.retrySafety = 'never_retry',
    ConcurrencyPolicy? concurrency,
    this.resolveHandles = true,
    OutputPolicy? outputPolicy,
    this.compensation,
  })  : concurrency = concurrency ?? ConcurrencyPolicy(),
        outputPolicy = outputPolicy ?? OutputPolicy() {
    if (!retrySafetyKinds.contains(retrySafety)) {
      throw ArgumentError(
          'retry_safety must be one of $retrySafetyKinds, got "$retrySafety"');
    }
    if (retries > 0 && !(retrySafety == 'pure' || retrySafety == 'idempotent')) {
      throw ArgumentError(
          'retries=$retries is unsafe for retry_safety="$retrySafety"; '
          "only 'pure' or 'idempotent' capabilities may set retries > 0");
    }
  }

  /// Either a [PlainHandler] or a [CtxHandler], selected by `wantsCtx` on
  /// the owning [Capability]. Replaces Python's `handler_ref` + `importlib`
  /// dynamic-import path, which has no Dart equivalent.
  final Function? handler;
  final String handlerRef;
  final double timeoutS;
  final int retries;
  final String retrySafety;
  final ConcurrencyPolicy concurrency;
  final bool resolveHandles;
  final OutputPolicy outputPolicy;
  final String? compensation;
}

const Map<String, String> _jsonToDartType = {
  'string': 'String',
  'integer': 'int',
  'number': 'double',
  'boolean': 'bool',
  'array': 'List',
  'object': 'Map',
  'null': 'null',
};

String _typeStr(Map<String, Object?> schema) {
  final t = schema['type'];
  if (t is List) {
    return t.map((x) => _jsonToDartType[x] ?? x.toString()).join(' | ');
  }
  if (t is String) {
    return _jsonToDartType[t] ?? t;
  }
  if (schema.containsKey('enum')) {
    final values = (schema['enum'] as List).map((v) => jsonEncode(v)).join(', ');
    return 'Literal[$values]';
  }
  return 'Object?';
}

/// Build a python-ish signature string from a JSON Schema.
String synthesizeSignature(
  String name,
  Map<String, Object?> parameters, [
  Map<String, Object?>? returns,
]) {
  final props =
      (parameters['properties'] as Map?)?.cast<String, Object?>() ?? {};
  final required =
      ((parameters['required'] as List?) ?? []).cast<String>().toSet();
  final parts = <String>[];
  for (final entry in props.entries) {
    final sch = entry.value is Map
        ? (entry.value as Map).cast<String, Object?>()
        : <String, Object?>{};
    var piece = '${entry.key}: ${_typeStr(sch)}';
    if (!required.contains(entry.key)) {
      if (sch.containsKey('default')) {
        piece += ' = ${jsonEncode(sch['default'])}';
      } else {
        piece += ' = None';
      }
    }
    parts.add(piece);
  }
  final ret = returns != null ? _typeStr(returns) : 'Object?';
  return '$name(${parts.join(', ')}) -> $ret';
}

String _firstSentence(String text) {
  final trimmed = text.trim().split('\n').first;
  for (final sep in ['。', '. ']) {
    if (trimmed.contains(sep)) {
      return trimmed.split(sep).first + sep.trim();
    }
  }
  return trimmed;
}

final RegExp _nameRe =
    RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,4}$');

/// Many native-function-calling providers (OpenAI included) reject "." in a
/// function name (they require `^[a-zA-Z0-9_-]+$`). The dotted name is the
/// capability's real, canonical identity everywhere else (registry, ledger,
/// policy patterns); `apiName` is only a wire-safe encoding of it for the
/// tool schema sent to the provider. "__" is reserved as that encoding's
/// segment separator, so a name may not contain it.
const String apiNameSeparator = '__';

/// Enforce the 2-5 level dotted namespace convention (service.resource.op).
void validateCapabilityName(String name) {
  if (!_nameRe.hasMatch(name)) {
    throw ArgumentError(
        'Capability name "$name" must be 2-5 lowercase dotted segments, '
        "e.g. 'filesystem.file.read' or 'github.pull_request.create'");
  }
  if (name.contains(apiNameSeparator)) {
    throw ArgumentError(
        'Capability name "$name" must not contain "$apiNameSeparator" '
        '(reserved for the provider-safe api_name encoding)');
  }
}

/// Dotted capability name -> provider-safe function name.
String toApiName(String name) => name.replaceAll('.', apiNameSeparator);

/// Provider-safe function name -> dotted capability name.
String fromApiName(String apiName) =>
    apiName.replaceAll(apiNameSeparator, '.');

class Capability {
  Capability({
    required this.name,
    this.version = 1,
    this.category = '',
    CapabilityCard? card,
    CapabilitySpec? spec,
    CapabilityDiscovery? discovery,
    CapabilityExecution? execution,
    List<Effect>? effects,
    this.permission = '',
    this.wantsCtx = false,
  })  : card = card ?? CapabilityCard(),
        spec = spec ?? CapabilitySpec(),
        discovery = discovery ?? CapabilityDiscovery(),
        execution = execution ?? CapabilityExecution(),
        effects = effects ?? <Effect>[] {
    validateCapabilityName(name);
  }

  final String name;
  final int version;
  final String category;
  final CapabilityCard card;
  final CapabilitySpec spec;
  final CapabilityDiscovery discovery;
  final CapabilityExecution execution;
  final List<Effect> effects;
  final String permission;
  bool wantsCtx;

  String get qualifiedName => '$name@$version';

  /// Provider-safe function name for native tool-calling schemas.
  String get apiName => toApiName(name);

  /// Undeclared effects are NOT treated as pure — see `PolicyEngine.evaluate`
  /// and `Runtime._isReadOnly` for the same conservative default.
  bool get isPure => effects.isNotEmpty && effects.every((e) => e.kind == 'none');

  /// Build a [Capability] from a plain-map definition (the only
  /// construction path in this port — see the library note about dropped
  /// function introspection).
  factory Capability.fromMap(
    Map<String, Object?> data, {
    Function? handler,
    bool wantsCtx = false,
  }) {
    final name = data['name'] as String?;
    if (name == null || name.isEmpty) {
      throw ArgumentError("Capability definition requires a 'name'");
    }
    final specD = (data['spec'] as Map?)?.cast<String, Object?>() ?? {};
    final spec = CapabilitySpec(
      description: (specD['description'] as String?) ?? '',
      parameters: (specD['parameters'] as Map?)?.cast<String, Object?>() ??
          {'type': 'object', 'properties': {}},
      returns: (specD['returns'] as Map?)?.cast<String, Object?>(),
      usageNotes: (specD['usage_notes'] as String?) ?? '',
      examples: [
        for (final e in (specD['examples'] as List? ?? []))
          (e as Map).cast<String, Object?>(),
      ],
    );
    final cardD = (data['card'] as Map?)?.cast<String, Object?>() ?? {};
    final card = CapabilityCard(
      summary: (cardD['summary'] as String?) ?? '',
      signature: (cardD['signature'] as String?) ?? '',
      tags: ((cardD['tags'] as List?) ?? []).cast<String>(),
    );
    final discD = (data['discovery'] as Map?)?.cast<String, Object?>() ?? {};
    final discovery = CapabilityDiscovery(
      pinned: (discD['pinned'] as bool?) ?? false,
      requireSpec: (discD['require_spec'] as bool?) ?? false,
      embeddingText: (discD['embedding_text'] as String?) ?? '',
      noEmbed: (discD['no_embed'] as bool?) ?? false,
    );
    final exeD = (data['execution'] as Map?)?.cast<String, Object?>() ?? {};
    final opD =
        (exeD['output_policy'] as Map?)?.cast<String, Object?>() ?? {};
    final concD =
        (exeD['concurrency'] as Map?)?.cast<String, Object?>() ?? {};
    final execution = CapabilityExecution(
      handler: handler,
      handlerRef: exeD['handler'] is String ? exeD['handler'] as String : '',
      timeoutS: ((exeD['timeout_s'] as num?) ?? 30.0).toDouble(),
      retries: (exeD['retries'] as num?)?.toInt() ?? 0,
      retrySafety: (exeD['retry_safety'] as String?) ?? 'never_retry',
      concurrency: ConcurrencyPolicy(
        mode: (concD['mode'] as String?) ?? 'sequential_only',
        resourceKey: concD['resource_key'] as String?,
      ),
      resolveHandles: (exeD['resolve_handles'] as bool?) ?? true,
      outputPolicy: OutputPolicy(
        maxInlineTokens: (opD['max_inline_tokens'] as num?)?.toInt(),
        overflow: (opD['overflow'] as String?) ?? 'artifact',
        preview: (opD['preview'] as String?) ?? 'head',
      ),
      compensation: exeD['compensation'] as String?,
    );
    final effects = [
      for (final e in (data['effects'] as List? ?? []))
        Effect(
          kind: ((e as Map)['kind'] as String?) ?? 'none',
          resource: (e['resource'] as String?) ?? '*',
        ),
    ];
    final cap = Capability(
      name: name,
      version: (data['version'] as num?)?.toInt() ?? 1,
      category: (data['category'] as String?) ?? '',
      card: card,
      spec: spec,
      discovery: discovery,
      execution: execution,
      effects: effects,
      permission: (data['permission'] as String?) ?? '',
    );
    cap.deriveCard();
    cap.wantsCtx = wantsCtx;
    return cap;
  }

  void deriveCard() {
    if (card.summary.isEmpty) {
      final s = _firstSentence(spec.description);
      card.summary = s.isEmpty ? name : s;
    }
    if (card.signature.isEmpty) {
      card.signature = synthesizeSignature(name, spec.parameters, spec.returns);
    }
  }

  /// ~30-token one-liner: enough to call the capability directly.
  String cardText() {
    final sig = card.signature.isEmpty ? name : card.signature;
    return '- $sig — ${card.summary}';
  }

  String specText() {
    final lines = <String>['### $qualifiedName', card.signature];
    if (spec.description.isNotEmpty) lines.add(spec.description);
    lines.add('Parameters (JSON Schema): ${jsonEncode(spec.parameters)}');
    if (spec.returns != null) {
      lines.add('Returns: ${jsonEncode(spec.returns)}');
    }
    if (effects.isNotEmpty) {
      lines.add('Effects: ${effects.map((e) => '${e.kind}:${e.resource}').join(', ')}');
    }
    if (spec.usageNotes.isNotEmpty) {
      lines.add('Usage notes: ${spec.usageNotes}');
    }
    for (final ex in spec.examples) {
      final call = jsonEncode(ex['call'] ?? {});
      final note = (ex['note'] as String?) ?? '';
      lines.add('Example: $name($call)${note.isNotEmpty ? ' — $note' : ''}');
    }
    return lines.join('\n');
  }

  /// OpenAI-style function schema for native tool calling.
  ///
  /// Uses [apiName] (dots encoded as `__`), not the dotted [name] directly —
  /// most native-function-calling providers, OpenAI included, reject "." in
  /// a function name. Callers translate the name back with [fromApiName]
  /// (see `Registry.resolveApiName`) before the call reaches the registry.
  Map<String, Object?> apiSchema() {
    var description = spec.description.isEmpty ? card.summary : spec.description;
    if (spec.usageNotes.isNotEmpty) {
      description = '$description\nUsage: ${spec.usageNotes}';
    }
    return {
      'type': 'function',
      'function': {
        'name': apiName,
        'description': description,
        'parameters': spec.parameters,
      },
    };
  }

  String embeddingSource() {
    if (discovery.embeddingText.isNotEmpty) return discovery.embeddingText;
    final parts = [card.summary, ...card.tags];
    return parts.where((p) => p.isNotEmpty).join(' ');
  }
}
