/// Capability registry (layer 1 TOC, ToolProvider sync).
///
/// One of the three nouns. Owns every [Capability] and exposes:
///
/// * [Registry.tocText] — the layer-1 table of contents (category names +
///   counts)
/// * [Registry.epoch] — bumped on any mutation so epoch-cached sections and
///   search indexes know when to rebuild (`cacheClass="epoch"`)
/// * [ToolProvider] — a pluggable source of capabilities (e.g. an MCP-like
///   external server) synced via [Registry.refreshProviders]
/// * [Registry.subset] — scoped views for sub-agents (spawn tool_scope)
///
/// Capabilities are versioned (`name@version`); [Registry.get] without a
/// version resolves to the highest registered version, so a call site
/// written against the bare name always gets the latest contract without
/// touching config.
library;

import 'capability.dart';

/// External source of capability definitions.
abstract interface class ToolProvider {
  Iterable<Object> provide(); // Capability | Map
}

/// One scope entry against one capability.
///
/// An entry matches a capability name exactly, a category exactly, or a
/// category prefix written as `"cat/*"`. Shared by [Registry.subset] (an
/// allow-list for sub-agents) and [Registry.disable] (a deny-list).
bool scopeMatches(String entry, String name, String category) {
  if (entry == name || entry == category) return true;
  return entry.endsWith('/*') &&
      category.startsWith(entry.substring(0, entry.length - 1));
}

/// Every capability in the system, and the single gate the model sees it
/// through.
///
/// Both [capabilities] and [get] skip disabled capabilities, and every other
/// surface — the TOC, pinned specs, native tool schemas, layer-2 candidates,
/// `meta.tool.find`, and execution — derives from those two. Disabling
/// therefore removes a capability from all of them at once.
class Registry {
  Registry({Iterable<String> disabled = const []})
      : _disabled = disabled.toSet();

  final Map<String, Capability> _capabilities = {}; // keyed by qualifiedName
  final Map<String, String> _latest = {}; // name -> qualifiedName of highest version
  int _epoch = 0;
  // A deny-list of names/categories, not of registered objects: a disabled
  // name stays disabled however it is registered afterwards, so a bundled
  // pack installed later (installBuiltins) cannot sneak it back in.
  final Set<String> _disabled;
  (int, List<Capability>) _pinnedCache = (-1, const []);
  final List<ToolProvider> _providers = [];
  final Map<int, Set<String>> _providerTools = {};

  // -- mutation -------------------------------------------------------------

  Capability register(
    Object capability, {
    Function? handler,
    bool wantsCtx = false,
    bool replace = false,
  }) {
    final cap = _coerce(capability, handler: handler, wantsCtx: wantsCtx);
    if (_capabilities.containsKey(cap.qualifiedName) && !replace) {
      throw ArgumentError(
          'Capability "${cap.qualifiedName}" is already registered (use replace=true)');
    }
    _capabilities[cap.qualifiedName] = cap;
    final current = _latest[cap.name];
    if (current == null || _capabilities[current]!.version < cap.version) {
      _latest[cap.name] = cap.qualifiedName;
    }
    _epoch += 1;
    return cap;
  }

  /// Remove by bare name (all versions) or exact `name@version`.
  void unregister(String name) {
    if (_capabilities.containsKey(name)) {
      _capabilities.remove(name);
      _recomputeLatest();
      _epoch += 1;
      return;
    }
    final removed = _capabilities.keys
        .where((q) => q.substring(0, q.lastIndexOf('@')) == name)
        .toList();
    if (removed.isNotEmpty) {
      for (final q in removed) {
        _capabilities.remove(q);
      }
      _recomputeLatest();
      _epoch += 1;
    }
  }

  void _recomputeLatest() {
    _latest.clear();
    for (final cap in _capabilities.values) {
      final current = _latest[cap.name];
      if (current == null || _capabilities[current]!.version < cap.version) {
        _latest[cap.name] = cap.qualifiedName;
      }
    }
  }

  static Capability _coerce(Object capability,
      {Function? handler, bool wantsCtx = false}) {
    if (capability is Capability) {
      if (handler != null) {
        throw ArgumentError(
            'Capability "${capability.name}" already carries its own handler; '
            'pass a handler only when registering a definition map');
      }
      return capability;
    }
    if (capability is Map) {
      return Capability.fromMap(capability.cast<String, Object?>(),
          handler: handler, wantsCtx: wantsCtx);
    }
    throw ArgumentError('Cannot register $capability as a capability');
  }

  // -- providers ------------------------------------------------------------

  void attachProvider(ToolProvider provider, {bool refresh = true}) {
    _providers.add(provider);
    if (refresh) refreshProviders();
  }

  /// Sync provider-supplied capabilities; adds/removes bump the epoch once.
  void refreshProviders() {
    var changed = false;
    for (final provider in _providers) {
      final pid = identityHashCode(provider);
      final fresh = <String, Capability>{
        for (final c in provider.provide().map((c) => _coerce(c)))
          c.qualifiedName: c,
      };
      final previous = _providerTools[pid] ?? <String>{};
      for (final qname in previous.difference(fresh.keys.toSet())) {
        if (_capabilities.containsKey(qname)) {
          _capabilities.remove(qname);
          changed = true;
        }
      }
      for (final entry in fresh.entries) {
        if (!identical(_capabilities[entry.key], entry.value)) {
          _capabilities[entry.key] = entry.value;
          changed = true;
        }
      }
      _providerTools[pid] = fresh.keys.toSet();
    }
    if (changed) {
      _recomputeLatest();
      _epoch += 1;
    }
  }

  // -- disabling ------------------------------------------------------------

  Set<String> get disabled => Set.unmodifiable(_disabled);

  /// Hide capabilities from the model entirely.
  ///
  /// Entries follow [scopeMatches]. A disabled capability is gone from the
  /// tool index, pinned specs, native schemas, search and execution alike —
  /// the model can neither see it nor call it.
  void disable(Iterable<String> names) {
    final added = names.toSet().difference(_disabled);
    if (added.isNotEmpty) {
      _disabled.addAll(added);
      _epoch += 1;
    }
  }

  /// Undo [disable] for the given entries.
  void enable(Iterable<String> names) {
    final removed = _disabled.intersection(names.toSet());
    if (removed.isNotEmpty) {
      _disabled.removeAll(removed);
      _epoch += 1;
    }
  }

  static String _categoryOf(Capability c) => c.category.isEmpty ? 'misc' : c.category;

  bool _isDisabled(Capability capability) {
    if (_disabled.isEmpty) return false;
    return _disabled.any((e) => scopeMatches(e, capability.name, _categoryOf(capability)));
  }

  // -- lookup ---------------------------------------------------------------

  int get epoch => _epoch;

  /// Resolve by `name@version` (exact) or bare `name` (latest).
  ///
  /// Disabled capabilities resolve to null, exactly like unregistered ones —
  /// that is what makes them unreachable from the runtime.
  Capability? get(String name) {
    var capability = _capabilities[name];
    if (capability == null) {
      final qname = _latest[name];
      capability = qname != null ? _capabilities[qname] : null;
    }
    if (capability == null || _isDisabled(capability)) return null;
    return capability;
  }

  /// Translate a provider-safe `apiName` (see [Capability.apiName]) back to
  /// the registered dotted name, if it resolves to one.
  ///
  /// Names that already resolve directly (a bare or qualified dotted name)
  /// are returned unchanged; a name that doesn't resolve even after decoding
  /// is also returned unchanged, so the normal "unknown capability" error
  /// path still reports the name the model actually sent.
  String resolveApiName(String name) {
    if (get(name) != null) return name;
    final dotted = fromApiName(name);
    if (get(dotted) != null) return dotted;
    return name;
  }

  bool contains(String name) => get(name) != null;

  int get length => capabilities.length;

  /// Latest version of every reachable capability, in registration order.
  Iterable<Capability> get capabilities =>
      _latest.values.map((q) => _capabilities[q]!).where((c) => !_isDisabled(c));

  List<Capability> all() => capabilities.toList();

  /// Cached by epoch: this is read several times per turn (native schemas,
  /// the kernel section, the layer-2 exclusion set).
  List<Capability> pinned() {
    if (_pinnedCache.$1 != _epoch) {
      _pinnedCache = (_epoch, capabilities.where((c) => c.discovery.pinned).toList());
    }
    return _pinnedCache.$2;
  }

  /// Sorted category -> (total, pinned) counts.
  Map<String, (int, int)> categories() {
    final totals = <String, int>{};
    final pinnedCounts = <String, int>{};
    for (final c in capabilities) {
      final cat = _categoryOf(c);
      totals[cat] = (totals[cat] ?? 0) + 1;
      if (c.discovery.pinned) {
        pinnedCounts[cat] = (pinnedCounts[cat] ?? 0) + 1;
      }
    }
    final sortedKeys = totals.keys.toList()..sort();
    return {
      for (final cat in sortedKeys) cat: (totals[cat]!, pinnedCounts[cat] ?? 0),
    };
  }

  // -- layer 1: table of contents -------------------------------------------

  /// Compact category index with pinned counts, e.g.
  /// `meta(2p) game/media(3) file(2, 1p)`.
  ///
  /// Above [maxCategories] the index collapses to top-level categories only
  /// (hierarchise when the TOC itself grows too large).
  String tocText({int maxCategories = 60}) {
    var catInfo = categories();
    if (catInfo.length > maxCategories) {
      final topTotals = <String, int>{};
      final topPinned = <String, int>{};
      for (final entry in catInfo.entries) {
        final root = entry.key.split('/').first;
        topTotals[root] = (topTotals[root] ?? 0) + entry.value.$1;
        topPinned[root] = (topPinned[root] ?? 0) + entry.value.$2;
      }
      final sortedKeys = topTotals.keys.toList()..sort();
      catInfo = {
        for (final cat in sortedKeys) cat: (topTotals[cat]!, topPinned[cat] ?? 0),
      };
    }

    final parts = <String>[];
    for (final entry in catInfo.entries) {
      final cat = entry.key;
      final total = entry.value.$1;
      final p = entry.value.$2;
      if (p == total && total > 0) {
        parts.add('$cat(${total}p)');
      } else if (p > 0) {
        parts.add('$cat($total, ${p}p)');
      } else {
        parts.add('$cat($total)');
      }
    }
    return parts.join(' ');
  }

  // -- scoped views for sub-agents -------------------------------------------

  /// New registry containing only the named capabilities/categories.
  ///
  /// Scope entries follow [scopeMatches]. Capabilities disabled here are
  /// already invisible to the iteration, and the deny-list carries over so
  /// they stay disabled in the child.
  Registry subset(Iterable<String> scope) {
    final scopeList = scope.toList();
    final sub = Registry(disabled: _disabled);
    for (final c in capabilities) {
      if (scopeList.any((entry) => scopeMatches(entry, c.name, _categoryOf(c)))) {
        sub._capabilities[c.qualifiedName] = c;
      }
    }
    sub._recomputeLatest();
    sub._epoch = 1;
    return sub;
  }
}
