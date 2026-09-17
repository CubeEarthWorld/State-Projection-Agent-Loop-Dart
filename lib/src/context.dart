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

  String get runId => run?.id ?? '';

  /// The handler-facing view of this context for one command.
  ToolContext forCommand(String commandId) => ToolContext(
        config: config,
        registry: registry,
        ledger: ledger,
        run: run,
        workingState: workingState,
        session: session,
        store: store,
        search: search,
        commandId: commandId,
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
    List<ScoredTool>? candidates,
    List<Map<String, Object?>>? apiTools,
  })  : candidates = candidates ?? <ScoredTool>[],
        apiTools = apiTools ?? <Map<String, Object?>>[];

  final List<ScoredTool> candidates;
  List<Map<String, Object?>> apiTools;
}
