/// Resident checklist tool; all operations use the session's working state.
library;

import '../capability.dart';
import '../registry.dart';
import '../working_state.dart';
import '../checklists.dart';
import '../events.dart';
import '../run.dart';
import 'defs.g.dart';

Object? _checklist(ToolContext ctx, Map<String, Object?> args) {
  final arguments = Map<String, Object?>.from(args);
  final action = arguments.remove('action') as String;
  final ws = ctx.workingState as WorkingState;
  if (['list', 'get', 'export'].contains(action)) {
    return ws.checklists.execute(action, arguments);
  }
  final updated = ChecklistStore.fromDict(ws.checklists.toDict());
  final result = updated.execute(action, arguments);
  final ledger = ctx.ledger as EventLedger?;
  final run = ctx.run as Run?;
  if (ledger != null && run != null) {
    ledger.append(run.id, 'checklists_changed', {
      'action': action,
      'command_id': ctx.commandId,
      'checklists': updated.toDict(),
    });
  }
  ws.checklists = updated;
  return result;
}

void ensureChecklistTool(Registry registry) {
  if (!registry.contains('planning.checklist.manage')) {
    registry.register((load('checklist') as Map).cast<String, Object?>(),
        handler: _checklist, wantsCtx: true);
  }
}
