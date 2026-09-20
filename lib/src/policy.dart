/// Policy engine: the sole owner of execution permission.
///
/// The LLM proposes; it never decides. Every planned effect of a capability
/// call is evaluated here, in a fixed layer order, before the runtime is
/// allowed to execute anything:
///
///     absolute > admin > developer > workspace/user > session > llm
///
/// A `deny` at any layer can never be relaxed by a layer below it — this is
/// enforced structurally by taking the *most restrictive* verdict across all
/// matching layers, not by "last write wins". The LLM's own layer is the
/// lowest priority and, depending on `llmSafetyMode`, is either ignored
/// entirely, advisory-only (recorded but never changes the outcome), or
/// capped at `require_approval` — it can never single-handedly grant
/// `allow` or issue a final `deny`.
///
/// Declared effects ([Effect]) are self-reported by the capability author.
/// This engine is the *policy* boundary, not the *sandbox* boundary —
/// pairing it with OS/process-level restrictions on network, filesystem and
/// credentials is the caller's responsibility.
library;

import 'capability.dart';

const List<String> layerOrder = [
  'absolute',
  'admin',
  'developer',
  'workspace',
  'session',
  'llm',
];
const List<String> decisions = ['allow', 'deny', 'require_approval'];
const Map<String, int> _severity = {'allow': 1, 'require_approval': 2, 'deny': 3};

/// Convenience scopes mapped onto effect-kind + resource patterns.
const Map<String, (String?, String)> scopes = {
  'workspace_read': ('read', 'workspace:*'),
  'workspace_write': ('write', 'workspace:*'),
  'sandbox_command': (null, 'sandbox:*'),
  'network_access': (null, 'network:*'),
  'external_mutation': ('external', '*'),
  'secrets_access': (null, 'secrets:*'),
  'host_access': (null, 'host:*'),
};

const List<String> presets = [
  'deny_all',
  'approve_all_effects',
  'auto_safe',
  'auto_workspace_dev',
];

/// One character in fnmatch's sense: a Unicode code point, not a UTF-16
/// code unit. Python strings are code points, so `fnmatch("🎌", "?")` is
/// true there and `.` alone (one code unit) would make it false here.
const String _oneChar = r'(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|.)';

/// Escape what a regex character class reads as syntax but fnmatch reads as
/// a literal. The range hyphens are added back between chunks.
String _escapeClassChunk(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll('^', r'\^')
    .replaceAll('[', r'\[')
    .replaceAll(']', r'\]')
    .replaceAll('-', r'\-');

/// Translate a Python-`fnmatch`-style glob pattern (`*`, `?`, `[seq]`,
/// `[!seq]`) into an anchored [RegExp].
///
/// Deliberately `fnmatch`-compatible, not regex-compatible: `!` is the only
/// negation character, `^` inside a class is a literal, `*`/`?` match
/// newlines, `?` matches one code point, and — as in CPython's
/// `fnmatch.translate` — a range whose start sorts after its end is empty
/// and simply drops out, so `[z-a]` matches nothing and `[!z-a]` matches
/// any character instead of being a regex error. A policy pattern that
/// means one thing here and another in the Python package would flip a
/// `deny` into an `allow`; a pattern that *throws* would take authorization
/// down with it.
RegExp globToRegExp(String pattern) {
  final buf = StringBuffer('^');
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      buf.write('.*');
    } else if (c == '?') {
      buf.write(_oneChar);
    } else if (c == '[') {
      var j = i + 1;
      var negate = false;
      if (j < pattern.length && pattern[j] == '!') {
        negate = true;
        j++;
      }
      // fnmatch: a ']' immediately after the (optional) '!' is a literal
      // member of the class, not the closing bracket.
      final bodyStart = j;
      if (j < pattern.length && pattern[j] == ']') j++;
      while (j < pattern.length && pattern[j] != ']') {
        j++;
      }
      if (j >= pattern.length) {
        buf.write(RegExp.escape(c)); // unterminated '[' is a literal
      } else {
        buf.write(_classRegExp(pattern.substring(bodyStart, j), negate));
        i = j;
      }
    } else {
      buf.write(RegExp.escape(c));
    }
    i++;
  }
  buf.write(r'$');
  return RegExp(buf.toString(), dotAll: true);
}

/// The regex for one `[...]` class body (the `!` already stripped into
/// [negate]). Mirrors CPython's chunk-merging, which drops both endpoints
/// of an empty range.
String _classRegExp(String body, bool negate) {
  var chunks = <String>[body];
  if (body.contains('-')) {
    chunks = [];
    var start = 0;
    // A '-' in first position is a literal, never a range separator.
    var k = 1;
    while (k <= body.length) {
      k = body.indexOf('-', k);
      if (k < 0) break;
      chunks.add(body.substring(start, k));
      start = k + 1; // the range's end character
      k += 3; // earliest position of the next range's '-'
    }
    final tail = body.substring(start);
    if (tail.isNotEmpty) {
      chunks.add(tail);
    } else {
      chunks[chunks.length - 1] += '-'; // trailing '-' is a literal
    }
    for (var m = chunks.length - 1; m > 0; m--) {
      final lo = chunks[m - 1][chunks[m - 1].length - 1];
      if (lo.compareTo(chunks[m][0]) > 0) {
        chunks[m - 1] =
            chunks[m - 1].substring(0, chunks[m - 1].length - 1) + chunks[m].substring(1);
        chunks.removeAt(m);
      }
    }
  }
  final stuff = chunks.map(_escapeClassChunk).join('-');
  if (stuff.isEmpty) return negate ? _oneChar : '(?!)';
  return '[${negate ? '^' : ''}$stuff]';
}

bool globMatch(String value, String pattern) => globToRegExp(pattern).hasMatch(value);

typedef ArgPredicate = bool Function(Map<String, Object?> arguments);

class Rule {
  Rule({
    required this.decision, // one of `decisions`
    this.capabilityPattern = '*',
    this.effectKind, // null matches any effect kind
    this.resourcePattern = '*',
    this.argPredicate,
    this.reason = '',
  });

  final String decision;
  final String capabilityPattern;
  final String? effectKind;
  final String resourcePattern;
  final ArgPredicate? argPredicate;
  final String reason;

  /// Matches every call: the layer's fallback, consulted after every rule
  /// that names something (see `PolicyEngine._matchLayer`).
  bool get isCatchAll =>
      capabilityPattern == '*' && effectKind == null && resourcePattern == '*' && argPredicate == null;

  bool matches(Capability capability, Effect effect, Map<String, Object?> arguments) {
    if (!globMatch(capability.name, capabilityPattern)) return false;
    if (effectKind != null && effect.kind != effectKind) return false;
    if (!globMatch(effect.resource, resourcePattern)) return false;
    if (argPredicate != null && !argPredicate!(arguments)) return false;
    return true;
  }
}

class PolicyDecision {
  PolicyDecision({
    required this.decision,
    required this.reason,
    this.layer = '',
  });

  final String decision;
  final String reason;
  final String layer;
}

typedef PolicyChangeListener = void Function(String description);

class PolicyEngine {
  PolicyEngine({this.defaultDecision = 'require_approval', PolicyChangeListener? onChange})
      : _onChange = onChange {
    if (!decisions.contains(defaultDecision)) {
      throw ArgumentError('default_decision must be one of $decisions');
    }
    layers = {for (final name in layerOrder) name: <Rule>[]};
  }

  final String defaultDecision;
  String llmSafetyMode = 'disabled'; // disabled | advisory | approval_routing
  late final Map<String, List<Rule>> layers;
  int revision = 0;
  final PolicyChangeListener? _onChange;

  // -- mutation (each bumps the revision; a stale ApprovalRequest is
  //    detected by comparing revisions — see Run.resolveApproval) --------

  void _changed(String description) {
    revision += 1;
    _onChange?.call(description);
  }

  void addRule(String layer, Rule rule) {
    if (!layerOrder.contains(layer)) {
      throw ArgumentError('Unknown policy layer "$layer"; expected one of $layerOrder');
    }
    layers[layer]!.add(rule);
    _changed(
        'add_rule layer=$layer pattern=${rule.capabilityPattern} decision=${rule.decision}');
  }

  void clearLayer(String layer) {
    layers[layer] = [];
    _changed('clear_layer layer=$layer');
  }

  /// Grant/deny/gate one of the named scopes, e.g.
  /// `setScope("network_access", "deny")`.
  void setScope(String scope, String decision, {String layer = 'workspace'}) {
    final entry = scopes[scope];
    if (entry == null) {
      final known = (scopes.keys.toList()..sort()).join(', ');
      throw ArgumentError('Unknown scope "$scope"; expected one of $known');
    }
    final (effectKind, resourcePattern) = entry;
    addRule(
      layer,
      Rule(
        decision: decision,
        capabilityPattern: '*',
        effectKind: effectKind,
        resourcePattern: resourcePattern,
        reason: 'scope:$scope',
      ),
    );
  }

  void applyPreset(String preset, {String layer = 'workspace'}) {
    final rules = _presetRules(preset);
    clearLayer(layer);
    for (final rule in rules) {
      addRule(layer, rule);
    }
  }

  void setLlmSafetyMode(String mode) {
    if (!['disabled', 'advisory', 'approval_routing'].contains(mode)) {
      throw ArgumentError('llm_safety_mode must be disabled|advisory|approval_routing');
    }
    llmSafetyMode = mode;
    _changed('set_llm_safety_mode $mode');
  }

  // -- evaluation -----------------------------------------------------------

  /// The first matching rule in the layer. A rule that matches everything (a
  /// preset's closing `require_approval`) is the layer's fallback and is
  /// consulted last, so a grant added after `applyPreset` on the same layer
  /// takes effect instead of being shadowed by it.
  Rule? _matchLayer(
      String layer, Capability capability, Effect effect, Map<String, Object?> arguments) {
    final matched = [for (final rule in layers[layer]!) if (rule.matches(capability, effect, arguments)) rule];
    return matched.where((rule) => !rule.isCatchAll).firstOrNull ?? matched.firstOrNull;
  }

  (String, String, String) _evaluateEffect(
      Capability capability, Effect effect, Map<String, Object?> arguments) {
    // `best` tracks the most restrictive verdict among layers that actually
    // matched a rule. `defaultDecision` is a fallback used ONLY when no
    // layer matched anything — it must never compete in the severity race,
    // or a real "allow" rule could never beat a default that happens to be
    // stricter (and vice versa, defeating "most restrictive real rule
    // wins").
    (int, String, String, String)? best; // (severity, decision, layer, reason)
    for (final layer in layerOrder) {
      if (layer == 'llm' && llmSafetyMode == 'disabled') continue;
      final rule = _matchLayer(layer, capability, effect, arguments);
      if (rule == null) continue;
      var decision = rule.decision;
      if (layer == 'llm') {
        if (llmSafetyMode == 'advisory') {
          continue; // recorded by caller via decision reason text, never changes outcome
        }
        // approval_routing: LLM may only escalate toward approval, never
        // grant allow on its own and never issue the final deny by itself.
        decision = decision != 'allow' ? 'require_approval' : defaultDecision;
      }
      final severity = _severity[decision]!;
      if (best == null || severity > best.$1) {
        best = (severity, decision, layer, rule.reason);
      }
    }
    if (best == null) {
      return (defaultDecision, 'default', 'no matching rule');
    }
    return (best.$2, best.$3, best.$4);
  }

  PolicyDecision evaluate(Capability capability, Map<String, Object?> arguments) {
    // plannedEffects always yields at least one effect (an undeclared
    // capability gets a synthesized "external" one), so there is no empty
    // case to seed. Ties keep the first-listed effect.
    final effects = capability.plannedEffects;
    var worst = _evaluateEffect(capability, effects.first, arguments);
    for (final effect in effects.skip(1)) {
      final result = _evaluateEffect(capability, effect, arguments);
      if (_severity[result.$1]! > _severity[worst.$1]!) worst = result;
    }
    return PolicyDecision(decision: worst.$1, reason: worst.$3, layer: worst.$2);
  }
}

/// The rules a preset installs, in order.
List<Rule> _presetRules(String preset) {
  Rule rule(String decision, {String? effectKind, String resourcePattern = '*'}) => Rule(
      decision: decision,
      effectKind: effectKind,
      resourcePattern: resourcePattern,
      reason: 'preset:$preset');
  // Writes confined to the session's own working state never leave the
  // process, so the auto presets allow them; they are declared as writes so
  // the runtime keeps them in the model's stated order.
  final localState = [
    Rule(decision: 'allow', capabilityPattern: 'planning.checklist.manage',
        effectKind: 'write', resourcePattern: 'working_state:checklists', reason: 'preset:local_checklists'),
    Rule(decision: 'allow', capabilityPattern: 'meta.user.ask',
        effectKind: 'external', resourcePattern: 'user:*', reason: 'preset:ask_user'),
    // No effectKind: reads of the working state are covered too (a read is
    // strictly less dangerous than the writes right beside it), exactly
    // like the memory.* rule below.
    Rule(decision: 'allow', capabilityPattern: 'state.*',
        resourcePattern: 'working_state:*', reason: 'preset:local_working_state'),
    Rule(decision: 'allow', capabilityPattern: 'memory.*', resourcePattern: 'memory:*',
        reason: 'preset:local_memory'),
  ];
  return switch (preset) {
    'deny_all' => [rule('deny')],
    'approve_all_effects' => [rule('allow', effectKind: 'none'), rule('require_approval')],
    'auto_safe' => [
        ...localState,
        rule('allow', effectKind: 'none'),
        rule('allow', effectKind: 'read', resourcePattern: 'workspace:*'),
        rule('require_approval'),
      ],
    'auto_workspace_dev' => [
        ...localState,
        rule('allow', effectKind: 'none'),
        rule('allow', resourcePattern: 'workspace:*'),
        rule('allow', resourcePattern: 'sandbox:*'),
        rule('require_approval'),
      ],
    _ => throw ArgumentError('Unknown preset "$preset"; expected one of $presets'),
  };
}
