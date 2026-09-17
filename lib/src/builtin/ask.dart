/// Handler of the `ask` pack: `meta.user.ask` returns a [Question], which the
/// runtime turns into a `WAITING_FOR_USER` pause. `Session.answer` resumes.
library;

import '../capability.dart';
import '../run.dart' show Question;

Question _ask(ToolContext ctx, Map<String, Object?> args) => Question(
      args['question'] as String,
      choices: (args['choices'] as List?)?.cast<String>(),
    );

const Map<String, CtxHandler> askHandlers = {'meta.user.ask': _ask};
