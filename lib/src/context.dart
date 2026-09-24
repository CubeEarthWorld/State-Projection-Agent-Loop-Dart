/// The context objects of a turn.
///
/// [ToolContext] is what a tool handler receives: the session's services
/// plus the [commandId] of the call being executed. `commandId` is stable
/// across retries of the *same* logical attempt and is the correct
/// idempotency key to hand to an external API.
///
/// [TurnContext] is the superset a [Section] renders from: the same
/// services plus this turn's projection state (auto-selected candidates,
/// the native schemas being sent, the dedupe flag). Handlers never see those
/// fields — the runtime narrows a turn context with [ToolContext.forCommand]
/// before invoking a handler.
library;

import 'artifacts.dart';
import 'config.dart';
import 'discovery.dart' show ScoredTool, ToolSearch;
import 'events.dart';
import 'registry.dart';
import 'run.dart';
import 'working_state.dart';

void _noEmit(String text) {}

class ToolContext {
  ToolContext({
    required this.config,
    required this.registry,
    this.ledger,
    this.run,
    WorkingState? workingState,
    this.session,
    this.store,
    this.search,
    this.commandId = '',
    this.resolution,
    this.emit = _noEmit,
  }) : workingState = workingState ?? WorkingState();

  final Config config;
  final Registry registry;
  final EventLedger? ledger;
  final Run? run;
  final WorkingState workingState;
  final Object? session; // Session; untyped to keep session.dart the only importer of everything
  final ArtifactStore? store;
  final ToolSearch? search;
  final String commandId;
  // "approved" / "denied" when this command is being re-invoked after an
  // approval it raised itself by returning an ApprovalRequest; null on a
  // first call. A handler that never parks never sees anything else.
  final String? resolution;
  // Hands a chunk of the tool's progress output to the session's onDelta
  // observer, if any. Delivery only: nothing emitted reaches the ledger.
  final void Function(String text) emit;

  String get runId => run?.id ?? '';

  /// The handler-facing view of this context for one command. Spelled out
  /// rather than copied field-wise: `this` is usually a [TurnContext], and
  /// the point is to hand the handler a plain [ToolContext] instead.
  ToolContext forCommand(String commandId, {String? resolution}) => ToolContext(
        config: config,
        registry: registry,
        ledger: ledger,
        run: run,
        workingState: workingState,
        session: session,
        store: store,
        search: search,
        commandId: commandId,
        resolution: resolution,
        emit: emit,
      );
}

class TurnContext extends ToolContext {
  TurnContext({
    required super.config,
    required super.registry,
    super.ledger,
    super.run,
    super.workingState,
    super.session,
    super.store,
    super.search,
    super.emit,
    List<ScoredTool>? candidates,
    List<Map<String, Object?>>? apiTools,
    List<String>? toolRecency,
  })  : candidates = candidates ?? <ScoredTool>[],
        apiTools = apiTools ?? <Map<String, Object?>>[],
        toolRecency = toolRecency ?? <String>[];

  final List<ScoredTool> candidates;
  List<Map<String, Object?>> apiTools;

  /// The api names of the non-pinned native schemas, least recently used or
  /// offered first: the order the window budget gives them back in. The
  /// order of [apiTools] itself is the order they were first sent, which
  /// says nothing about which one matters least now.
  List<String> toolRecency;
}
