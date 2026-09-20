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
/// are always built via [Capability.fromDict] with an explicit handler and an
/// explicit `wantsCtx` flag, rather than derived from a decorated function.
library;

import 'dart:async';
import 'context.dart';
import 'serialization.dart';

export 'context.dart' show ToolContext;

const List<String> effectKinds = ['none', 'read', 'write', 'external'];
const List<String> retrySafetyKinds = [
  'pure',
  'idempotent',
  'check_then_retry',
  'never_retry',
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

  Map<String, Object?> toDict() => {'kind': kind, 'resource': resource};

  factory Effect.fromDict(Map<String, Object?> d) =>
      Effect(kind: (d['kind'] as String?) ?? 'none', resource: (d['resource'] as String?) ?? '*');
}

class CapabilityCard {
  CapabilityCard({this.summary = '', List<String>? tags})
      : tags = tags ?? <String>[];

  String summary;

  /// Derived from the name and parameters; never authored.
  String signature = '';
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
    this.kernelNote = '',
  });

  final bool pinned;
  final bool requireSpec;
  final String embeddingText;
  final bool noEmbed;

  /// One standing sentence for the kernel's "[Runtime notes]", shown while
  /// the capability is pinned and reachable. Pinned only: the pin set is
  /// the developer's own bound on kernel size.
  final String kernelNote;
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

class CapabilityExecution {
  CapabilityExecution({
    this.handler,
    this.timeoutS = 30.0,
    this.retries = 0,
    this.retrySafety = 'never_retry',
    this.resolveHandles = true,
    OutputPolicy? outputPolicy,
  }) : outputPolicy = outputPolicy ?? OutputPolicy() {
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
  /// Wall-clock budget for one attempt.
  ///
  /// Only enforceable against a handler that actually yields: Dart cannot
  /// interrupt a synchronous function, so a handler that blocks the isolate
  /// runs to completion however long it takes, and the timer only fires
  /// afterwards. Give any handler that can be slow an async body. (The
  /// Python package hands synchronous handlers to a worker thread, so this
  /// limitation is Dart's alone.)
  final double timeoutS;
  final int retries;
  final String retrySafety;
  final bool resolveHandles;
  final OutputPolicy outputPolicy;
}

/// Render a parameter's type for the signature line.
///
/// Deliberately the JSON Schema vocabulary, not a language's: the model sees
/// the same type names here and in the full spec below, and the Dart and
/// Python ports render one identical string instead of two dialects.
String _typeStr(Map<String, Object?> schema) {
  final t = schema['type'];
  if (t is List) return t.map((x) => x.toString()).join(' | ');
  if (t is String) return t;
  if (schema.containsKey('enum')) {
    final values = (schema['enum'] as List).map((v) => dumps(v)).join(', ');
    return 'Literal[$values]';
  }
  return 'any';
}

/// Build a signature string from a JSON Schema.
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
      piece += sch.containsKey('default') ? ' = ${dumps(sch['default'])}' : ' = null';
    }
    parts.add(piece);
  }
  final ret = returns != null ? _typeStr(returns) : 'any';
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
    this.wantsCtx = false,
  })  : card = card ?? CapabilityCard(),
        spec = spec ?? CapabilitySpec(),
        discovery = discovery ?? CapabilityDiscovery(),
        execution = execution ?? CapabilityExecution(),
        effects = effects ?? <Effect>[] {
    validateCapabilityName(name);
    _deriveCard();
  }

  final String name;
  final int version;
  final String category;
  final CapabilityCard card;
  final CapabilitySpec spec;
  final CapabilityDiscovery discovery;
  final CapabilityExecution execution;
  final List<Effect> effects;
  bool wantsCtx;

  String get qualifiedName => '$name@$version';

  /// Provider-safe function name for native tool-calling schemas.
  String get apiName => toApiName(name);

  /// The effects the policy engine and the runtime reason about. A
  /// capability that declares none is NOT assumed safe — that would reward an
  /// author who forgot to declare effects with maximum trust and free
  /// parallel execution — so it counts as the most restrictive kind.
  List<Effect> get plannedEffects =>
      effects.isNotEmpty ? effects : [Effect(kind: 'external', resource: 'undeclared:*')];

  /// Build a [Capability] from a plain-map definition (the only
  /// construction path in this port — see the library note about dropped
  /// function introspection).
  factory Capability.fromDict(
    Map<String, Object?> data, {
    Function? handler,
    bool wantsCtx = false,
  }) {
    final name = data.strOr('name');
    if (name.isEmpty) {
      throw ArgumentError("Capability definition requires a 'name'");
    }
    final cardD = data.sub('card');
    if (cardD.containsKey('signature')) {
      throw ArgumentError(
          'Capability "$name": card.signature is derived from the name and '
          'parameters, not authored — remove it from the definition');
    }
    final specD = data.sub('spec');
    final discD = data.sub('discovery');
    final exeD = data.sub('execution');
    final opD = exeD.sub('output_policy');
    final cap = Capability(
      name: name,
      version: data.intOr('version', 1),
      category: data.strOr('category'),
      card: CapabilityCard(summary: cardD.strOr('summary'), tags: cardD.strs('tags')),
      spec: CapabilitySpec(
        description: specD.strOr('description'),
        // Shared with the definition, not copied: callers rely on it.
        parameters: specD.mapOrNull('parameters'),
        returns: specD.mapOrNull('returns'),
        usageNotes: specD.strOr('usage_notes'),
        examples: specD.maps('examples'),
      ),
      discovery: CapabilityDiscovery(
        pinned: discD.boolOr('pinned', false),
        requireSpec: discD.boolOr('require_spec', false),
        embeddingText: discD.strOr('embedding_text'),
        noEmbed: discD.boolOr('no_embed', false),
        kernelNote: discD.strOr('kernel_note'),
      ),
      execution: CapabilityExecution(
        handler: handler,
        timeoutS: exeD.dblOr('timeout_s', 30.0),
        retries: exeD.intOr('retries', 0),
        retrySafety: exeD.strOr('retry_safety', 'never_retry'),
        resolveHandles: exeD.boolOr('resolve_handles', true),
        outputPolicy: OutputPolicy(
          maxInlineTokens: opD.intOrNull('max_inline_tokens'),
          overflow: opD.strOr('overflow', 'artifact'),
          preview: opD.strOr('preview', 'head'),
        ),
      ),
      effects: [for (final e in data.maps('effects')) Effect.fromDict(e)],
    );
    cap.wantsCtx = wantsCtx;
    return cap;
  }

  void _deriveCard() {
    if (card.summary.isEmpty) {
      final s = _firstSentence(spec.description);
      card.summary = s.isEmpty ? name : s;
    }
    // The signature is always derived, never authored: it is the one line
    // telling the model how to call this capability, and a hand-written one
    // drifts from the real name and parameters.
    card.signature = synthesizeSignature(name, spec.parameters, spec.returns);
  }

  /// ~30-token one-liner: enough to call the capability directly.
  String cardText() {
    return '- ${card.signature} — ${card.summary}';
  }

  String specText() {
    final lines = <String>['### $qualifiedName', card.signature];
    if (spec.description.isNotEmpty) lines.add(spec.description);
    lines.add('Parameters (JSON Schema): ${dumps(spec.parameters)}');
    if (spec.returns != null) {
      lines.add('Returns: ${dumps(spec.returns)}');
    }
    if (effects.isNotEmpty) {
      lines.add('Effects: ${effects.map((e) => '${e.kind}:${e.resource}').join(', ')}');
    }
    if (spec.usageNotes.isNotEmpty) {
      lines.add('Usage notes: ${spec.usageNotes}');
    }
    for (final ex in spec.examples) {
      final call = dumps(ex['call'] ?? {});
      final note = (ex['note'] as String?) ?? '';
      lines.add('Example: $name($call)${note.isNotEmpty ? ' — $note' : ''}');
    }
    return lines.join('\n');
  }

  /// Provider-neutral description of one callable tool.
  ///
  /// Deliberately just `name` / `description` / `parameters` (JSON Schema):
  /// the runtime states what the tool *is* and each adapter renders that
  /// into whatever its provider wants - OpenAI's
  /// `{'type': 'function', 'function': {...}}` envelope, Anthropic's
  /// `input_schema`, a text protocol, anything. Emitting one vendor's
  /// envelope from the core would make every other adapter unwrap it
  /// first, and would quietly make that vendor the default.
  ///
  /// Uses [apiName] (dots encoded as `__`), not the dotted [name]: most
  /// native-function-calling providers reject "." in a function name.
  Map<String, Object?> toolSpec() {
    var description = spec.description.isNotEmpty ? spec.description : card.summary;
    if (spec.usageNotes.isNotEmpty) {
      description = '$description\nUsage: ${spec.usageNotes}';
    }
    return {
      'name': apiName,
      'description': description,
      'parameters': spec.parameters,
    };
  }

  String embeddingSource() {
    if (discovery.embeddingText.isNotEmpty) return discovery.embeddingText;
    final parts = [card.summary, ...card.tags];
    return parts.where((p) => p.isNotEmpty).join(' ');
  }

  /// A copy of this capability wired to [handler].
  ///
  /// A copy, not a mutation: `subset()` hands the parent registry's
  /// capability objects straight to the child, so rewiring in place would
  /// let a sub-agent replace its parent's implementation mid-run.
  Capability withHandler(Function handler, {bool wantsCtx = false}) => Capability(
        name: name,
        version: version,
        category: category,
        card: card,
        spec: spec,
        discovery: discovery,
        execution: CapabilityExecution(
          handler: handler,
          timeoutS: execution.timeoutS,
          retries: execution.retries,
          retrySafety: execution.retrySafety,
          resolveHandles: execution.resolveHandles,
          outputPolicy: execution.outputPolicy,
        ),
        effects: effects,
        wantsCtx: wantsCtx,
      );
}

/// Typed reads of a raw JSON-ish map: a handler's arguments, or one level
/// of a capability definition.
///
/// The Python port's runtime hands each handler typed kwargs and reads a
/// definition with `dict.get(key, default)`; Dart has neither, and both
/// [Capability.fromDict] and every builtin were hand-unpacking maps the
/// same few ways. The `*OrNull` reads return null when the key is absent,
/// so a caller can tell "not given" from "given, empty" (Python's `None`
/// vs `[]`) and let a constructor's own default stand.
extension ToolArgs on Map<String, Object?> {
  String str(String key) => this[key] as String;
  String? strOrNull(String key) => this[key] as String?;
  String strOr(String key, [String fallback = '']) => (this[key] as String?) ?? fallback;
  bool boolOr(String key, bool fallback) => (this[key] as bool?) ?? fallback;
  int intOr(String key, int fallback) => (this[key] as num?)?.toInt() ?? fallback;
  int? intOrNull(String key) => (this[key] as num?)?.toInt();
  double dblOr(String key, double fallback) => (this[key] as num?)?.toDouble() ?? fallback;
  Map<String, Object?>? mapOrNull(String key) => (this[key] as Map?)?.cast<String, Object?>();
  Map<String, Object?> sub(String key) => mapOrNull(key) ?? const {};
  List<String> strs(String key) => ((this[key] as List?) ?? const []).cast<String>();
  List<String>? strsOrNull(String key) => (this[key] as List?)?.cast<String>();
  List<Map<String, Object?>> maps(String key) =>
      [for (final e in (this[key] as List?) ?? const []) (e as Map).cast<String, Object?>()];
}
