/// Bundled tool packs, and the one way to install them.
///
/// A pack is a JSON definition set (`spec/tools/<pack>.json`, shared byte
/// for byte with the Python package) plus a handler per tool. Handlers are
/// the only part written per language.
library;

import '../capability.dart';
import '../registry.dart';
import 'ask.dart' show askHandlers;
import 'checklist.dart' show checklistHandlers;
import 'defs.g.dart';
import 'memory.dart' show memoryHandlers;
import 'meta.dart' show metaHandlers, spawnHandlers;
import 'state.dart' show stateHandlers;

/// Packs a bare `Session(llm)` installs.
const Set<String> defaultBuiltins = {'meta', 'checklist'};

final Map<String, Map<String, CtxHandler>> _packs = {
  'meta': metaHandlers,
  'checklist': checklistHandlers,
  'state': stateHandlers,
  'spawn': spawnHandlers,
  'ask': askHandlers,
  'memory': memoryHandlers,
};

/// Every pack name [installBuiltins] accepts.
final Set<String> builtinPacks = _packs.keys.toSet();

/// Install the named packs into [registry].
///
/// Idempotent: a name the registry already resolves is left alone (a
/// developer's own definition wins). A name on the registry's deny-list is
/// registered but stays hidden — `disable` is the per-tool switch, `packs`
/// the per-pack one.
void installBuiltins(Registry registry, Iterable<String> packs) {
  for (final pack in packs) {
    final handlers = _packs[pack];
    if (handlers == null) {
      throw ArgumentError('Unknown builtin pack "$pack"; expected one of ${_packs.keys.toList()}');
    }
    install(registry, load(pack) as List, handlers, wantsCtx: true);
  }
}

/// Register each definition with its handler, unless the registry already
/// resolves that name.
void install(Registry registry, List<Object?> definitions, Map<String, Function> handlers,
    {bool wantsCtx = false}) {
  for (final def in definitions) {
    final map = (def as Map).cast<String, Object?>();
    final name = map['name'] as String;
    // hasDefinition, not contains: `get()` hides a *disabled* capability,
    // so a developer's own definition that happens to be switched off
    // would otherwise look unregistered and be replaced.
    if (registry.hasDefinition(name)) continue;
    final handler = handlers[name];
    if (handler == null) {
      // Python raises KeyError here. Registering a handler-less definition
      // instead would ship a tool that only fails when the model calls it.
      throw ArgumentError('No handler for builtin capability "$name"');
    }
    registry.register(map, handler: handler, wantsCtx: wantsCtx, replace: true);
  }
}
