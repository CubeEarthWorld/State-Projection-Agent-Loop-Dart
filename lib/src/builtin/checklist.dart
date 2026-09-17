/// Handler of the `checklist` pack; all operations use the session's
/// working state.
library;

import '../capability.dart';
import '../checklists.dart';

Object? _checklist(ToolContext ctx, Map<String, Object?> args) {
  final arguments = Map<String, Object?>.from(args);
  final action = arguments.remove('action') as String;
  final ws = ctx.workingState;
  if (['list', 'get', 'export'].contains(action)) {
    return ws.checklists.execute(action, arguments);
  }
  final updated = ChecklistStore.fromDict(ws.checklists.toDict());
  final result = updated.execute(action, arguments);
  final ledger = ctx.ledger;
  final run = ctx.run;
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

const Map<String, CtxHandler> checklistHandlers = {'planning.checklist.manage': _checklist};
