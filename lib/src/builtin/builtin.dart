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
    if (!registry.contains(name)) {
      registry.register(map, handler: handlers[name], wantsCtx: wantsCtx, replace: true);
    }
  }
}
