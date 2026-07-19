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

/// Translate a Python-`fnmatch`-style glob pattern (`*`, `?`, `[seq]`,
/// `[!seq]`) into an anchored [RegExp].
RegExp globToRegExp(String pattern) {
  final buf = StringBuffer('^');
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      buf.write('.*');
    } else if (c == '?') {
      buf.write('.');
    } else if (c == '[') {
      var j = i + 1;
      var negate = false;
      if (j < pattern.length && (pattern[j] == '!' || pattern[j] == '^')) {
        negate = true;
        j++;
      }
      final start = j;
      while (j < pattern.length && pattern[j] != ']') {
        j++;
      }
      if (j >= pattern.length) {
        buf.write(RegExp.escape(c));
      } else {
        final body = pattern.substring(start, j);
        buf.write('[${negate ? '^' : ''}$body]');
        i = j;
      }
    } else {
      buf.write(RegExp.escape(c));
    }
    i++;
  }
  buf.write(r'$');
  return RegExp(buf.toString());
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

  bool matches(Capability capability, Effect effect, Map<String, Object?> arguments) {
    if (!globMatch(capability.name, capabilityPattern)) return false;
    if (effectKind != null && effect.kind != effectKind) return false;
    if (!globMatch(effect.resource, resourcePattern)) return false;
    if (argPredicate != null && !argPredicate!(arguments)) return false;
    return true;
  }
}

typedef PerEffectEntry = (Effect, String, String); // (effect, decision, layer)

class PolicyDecision {
  PolicyDecision({
    required this.decision,
    required this.reason,
    this.layer = '',
    List<PerEffectEntry>? perEffect,
  }) : perEffect = perEffect ?? <PerEffectEntry>[];

  final String decision;
  final String reason;
  final String layer;
  final List<PerEffectEntry> perEffect;
}

typedef PolicyChangeListener = void Function(String description);

class PolicyEngine {
  PolicyEngine({String defaultDecision = 'require_approval', PolicyChangeListener? onChange})
      : defaultDecision = defaultDecision,
        _onChange = onChange {
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
    if (!presets.contains(preset)) {
      throw ArgumentError('Unknown preset "$preset"; expected one of $presets');
    }
    clearLayer(layer);
    switch (preset) {
      case 'deny_all':
        addRule(layer, Rule(decision: 'deny', reason: 'preset:deny_all'));
      case 'approve_all_effects':
        addRule(
            layer,
            Rule(
                decision: 'allow',
                effectKind: 'none',
                reason: 'preset:approve_all_effects'));
        addRule(
            layer,
            Rule(decision: 'require_approval', reason: 'preset:approve_all_effects'));
      case 'auto_safe':
        addRule(layer,
            Rule(decision: 'allow', effectKind: 'none', reason: 'preset:auto_safe'));
        addRule(
          layer,
          Rule(
              decision: 'allow',
              effectKind: 'read',
              resourcePattern: 'workspace:*',
              reason: 'preset:auto_safe'),
        );
        addRule(layer, Rule(decision: 'require_approval', reason: 'preset:auto_safe'));
      case 'auto_workspace_dev':
        addRule(
            layer,
            Rule(
                decision: 'allow',
                effectKind: 'none',
                reason: 'preset:auto_workspace_dev'));
        addRule(
          layer,
          Rule(
              decision: 'allow',
              resourcePattern: 'workspace:*',
              reason: 'preset:auto_workspace_dev'),
        );
        addRule(
          layer,
          Rule(
              decision: 'allow',
              resourcePattern: 'sandbox:*',
              reason: 'preset:auto_workspace_dev'),
        );
        addRule(
            layer,
            Rule(decision: 'require_approval', reason: 'preset:auto_workspace_dev'));
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

  Rule? _matchLayer(
      String layer, Capability capability, Effect effect, Map<String, Object?> arguments) {
    for (final rule in layers[layer]!) {
      if (rule.matches(capability, effect, arguments)) return rule;
    }
    return null;
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
    // A capability that declares no effects at all is NOT assumed safe —
    // that would reward an author who simply forgot to declare effects with
    // maximum trust. Treat undeclared effects as the most restrictive kind
    // so the default posture stays conservative.
    final effects = capability.effects.isNotEmpty
        ? capability.effects
        : [Effect(kind: 'external', resource: 'undeclared:*')];
    final perEffect = <PerEffectEntry>[];
    var worstDecision = 'allow';
    var worstLayer = 'default';
    var worstReason = 'no effects';
    var worstSeverity = 0;
    for (final effect in effects) {
      final (decision, layer, reason) = _evaluateEffect(capability, effect, arguments);
      perEffect.add((effect, decision, layer));
      final severity = _severity[decision]!;
      if (severity > worstSeverity) {
        worstDecision = decision;
        worstLayer = layer;
        worstReason = reason;
        worstSeverity = severity;
      }
    }
    return PolicyDecision(
        decision: worstDecision, reason: worstReason, layer: worstLayer, perEffect: perEffect);
  }
}

/// Small helper so callers don't hardcode a bare number of seconds.
class ApprovalExpiry {
  ApprovalExpiry({this.seconds = 3600.0});

  final double seconds;

  double at({double? now}) =>
      (now ?? DateTime.now().millisecondsSinceEpoch / 1000.0) + seconds;
}
