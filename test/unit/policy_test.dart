// Policy engine: layer priority (a deny at any layer can't be relaxed by
// a lower layer), scopes/presets, undeclared-effects default, LLM safety
// modes never granting a unilateral allow or the final deny.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

Capability cap({String name = 'demo.thing', List<Effect>? effects}) {
  return Capability(
    name: name,
    effects: effects ?? [Effect(kind: 'write', resource: 'workspace:*')],
  );
}

void main() {
  group('DefaultAndUndeclared', () {
    test('default decision used when nothing matches', () {
      final engine = PolicyEngine(defaultDecision: 'deny');
      final decision = engine.evaluate(cap(), {});
      expect(decision.decision, equals('deny'));
      expect(decision.layer, equals('default'));
    });

    test('undeclared effects are not treated as safe', () {
      final engine = PolicyEngine(defaultDecision: 'require_approval');
      engine.applyPreset('auto_safe'); // only allows effect_kind=none and workspace reads
      final noEffectsCap = Capability(name: 'demo.mystery'); // effects=[] declared
      final decision = engine.evaluate(noEffectsCap, {});
      // A forgotten effects declaration must NOT be rewarded with "allow":
      // undeclared effects synthesize as "external", which auto_safe's
      // effect_kind="none" rule does not match — only its catch-all
      // require_approval rule does.
      expect(decision.decision, equals('require_approval'));
    });
  });

  group('PresetFallback', () {
    test('a grant added after a preset is not shadowed by its catch-all', () {
      final engine = PolicyEngine(defaultDecision: 'require_approval');
      engine.applyPreset('auto_safe');
      engine.addRule('workspace', Rule(decision: 'allow', capabilityPattern: 'mail.*'));
      final send = cap(name: 'mail.message.send', effects: [Effect(kind: 'external', resource: 'smtp:*')]);
      final other = cap(name: 'crm.contact.update', effects: [Effect(kind: 'external', resource: 'crm:*')]);
      expect(engine.evaluate(send, {}).decision, equals('allow'));
      expect(engine.evaluate(other, {}).decision, equals('require_approval'));
    });
  });

  group('Layering', () {
    test('deny at higher layer cannot be relaxed by lower', () {
      final engine = PolicyEngine(defaultDecision: 'allow');
      engine.addRule('admin', Rule(decision: 'deny', capabilityPattern: 'demo.*'));
      engine.addRule('session', Rule(decision: 'allow', capabilityPattern: 'demo.*'));
      final decision = engine.evaluate(cap(), {});
      expect(decision.decision, equals('deny'));
      expect(decision.layer, equals('admin'));
    });

    test('most restrictive real rule wins even if less severe than default', () {
      // default is "deny" (most restrictive), but an actual matching rule
      // (even an "allow") must still be honored over the synthetic default.
      final engine = PolicyEngine(defaultDecision: 'deny');
      engine.addRule('workspace', Rule(decision: 'allow', effectKind: 'none'));
      final decision = engine.evaluate(cap(effects: [Effect(kind: 'none')]), {});
      expect(decision.decision, equals('allow'));
      expect(decision.layer, equals('workspace'));
    });
  });

  group('ScopesAndPresets', () {
    test('auto_safe allows pure and workspace read', () {
      final engine = PolicyEngine(defaultDecision: 'require_approval');
      engine.applyPreset('auto_safe');
      final pure = engine.evaluate(cap(effects: [Effect(kind: 'none')]), {});
      final read = engine.evaluate(
          cap(effects: [Effect(kind: 'read', resource: 'workspace:*')]), {});
      final write = engine.evaluate(
          cap(effects: [Effect(kind: 'write', resource: 'workspace:*')]), {});
      expect(pure.decision, equals('allow'));
      expect(read.decision, equals('allow'));
      expect(write.decision, equals('require_approval'));
    });

    test('deny_all preset', () {
      final engine = PolicyEngine();
      engine.applyPreset('deny_all');
      final decision = engine.evaluate(cap(effects: [Effect(kind: 'none')]), {});
      expect(decision.decision, equals('deny'));
    });

    test('set scope network', () {
      final engine = PolicyEngine(defaultDecision: 'allow');
      engine.setScope('network_access', 'deny');
      final decision = engine.evaluate(
          cap(effects: [Effect(kind: 'external', resource: 'network:api.example.com')]), {});
      expect(decision.decision, equals('deny'));
    });
  });

  group('Revision', () {
    test('mutation bumps revision', () {
      final engine = PolicyEngine();
      final r0 = engine.revision;
      engine.setScope('network_access', 'deny');
      expect(engine.revision, equals(r0 + 1));
    });

    test('onChange callback invoked', () {
      final calls = <String>[];
      final engine = PolicyEngine(onChange: calls.add);
      engine.setScope('network_access', 'deny');
      expect(calls.length, equals(1));
    });
  });

  group('LlmSafetyMode', () {
    test('disabled ignores llm layer', () {
      final engine = PolicyEngine(defaultDecision: 'require_approval');
      engine.addRule('llm', Rule(decision: 'allow'));
      final decision = engine.evaluate(
          cap(effects: [Effect(kind: 'write', resource: 'workspace:*')]), {});
      expect(decision.decision, equals('require_approval')); // llm layer never consulted
    });

    test('advisory never changes outcome', () {
      final engine = PolicyEngine(defaultDecision: 'require_approval');
      engine.setLlmSafetyMode('advisory');
      engine.addRule('llm', Rule(decision: 'deny'));
      final decision = engine.evaluate(
          cap(effects: [Effect(kind: 'write', resource: 'workspace:*')]), {});
      expect(decision.decision, equals('require_approval'));
    });

    test('approval_routing cannot grant bare allow', () {
      final engine = PolicyEngine(defaultDecision: 'deny');
      engine.setLlmSafetyMode('approval_routing');
      engine.addRule('llm', Rule(decision: 'allow'));
      final decision = engine.evaluate(
          cap(effects: [Effect(kind: 'write', resource: 'workspace:*')]), {});
      // LLM saying "allow" must never itself grant allow; falls back to default.
      expect(decision.decision, equals('deny'));
    });

    test('approval_routing can escalate to require_approval', () {
      final engine = PolicyEngine(defaultDecision: 'allow');
      engine.setLlmSafetyMode('approval_routing');
      engine.addRule('llm', Rule(decision: 'deny'));
      final decision = engine.evaluate(
          cap(effects: [Effect(kind: 'write', resource: 'workspace:*')]), {});
      expect(decision.decision, equals('require_approval'));
    });
  });

  group('AutoPresetsCoverStateReads', () {
    // The state.* preset rule named effectKind "write", so the one state
    // capability that declares a READ — `state.extra.get` — matched
    // nothing and fell through to require_approval, while every state
    // WRITE was auto-allowed.
    Capability stateCap(String kind) => Capability(
        name: kind == 'read' ? 'state.extra.get' : 'state.extra.set',
        effects: [Effect(kind: kind, resource: 'working_state:extra')]);

    test('reads and writes are both allowed', () {
      for (final preset in ['auto_safe', 'auto_workspace_dev']) {
        for (final kind in ['read', 'write']) {
          final engine = PolicyEngine();
          engine.applyPreset(preset);
          final decision = engine.evaluate(stateCap(kind), {});
          expect(decision.decision, equals('allow'), reason: '$preset/$kind');
          expect(decision.reason, equals('preset:local_working_state'));
        }
      }
    });
  });

  group('GlobDialect', () {
    // Pinned against Python's fnmatch; these two shapes are not in the
    // shared fixtures.
    test('question mark matches one code point not one utf16 unit', () {
      expect(globMatch('\u{1F38C}', '?'), isTrue);
      expect(globMatch('ab', '?'), isFalse);
    });

    test('an empty range declines instead of throwing', () {
      expect(globMatch('a', '[z-a]'), isFalse);
      expect(globMatch('a', '[!z-a]'), isTrue);
      expect(globMatch('ab', '[!z-a]'), isFalse);
    });
  });
}
