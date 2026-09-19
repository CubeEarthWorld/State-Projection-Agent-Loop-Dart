# state_projection_loop

**State-Projection Agent Loop** — a vendor-agnostic, resumable LLM agent
runtime built on two principles:

> Truth lives *outside* the context. Every turn, the prompt is re-rendered as
> a minimal, disposable **projection** of that truth.
>
> The LLM proposes; it never decides. Execution order, idempotency, policy
> authorization, and what actually happened are guaranteed by code, not by
> the model's good behavior.

This is a Dart port of the Python [`state-projection-loop`](https://github.com/mosimosi/State-Projection-Agent-Loop)
package. Conventional agent loops conflate the transcript, the source of
truth, and the model input — which structurally causes O(N) tool preloading,
batches that run out of the model's stated order, non-idempotent actions that
double-fire on a timeout, and "what happened?" being unanswerable after the
fact. This runtime decomposes that trinity and makes execution a real state
machine: an append-only **Event Ledger** is the only source of truth; a
**Run** can pause for approval, survive a process restart, and resume
exactly where it left off.

## The package is LLM-agnostic

`state_projection_loop` depends on **no LLM provider SDK**. It defines only
a two-method `LLMAdapter` interface (`Future<Decision> complete(messages,
[tools])`) and a scripted test double (`ScriptedLLM`) for deterministic
tests. Talking to a real model — OpenAI, Anthropic, DeepSeek, a local
server, anything — is entirely your own adapter, implementing that
interface however you like.

Tool schemas are provider-neutral too. `Capability.toolSpec()` returns plain
`{name, description, parameters}` (JSON Schema) and nothing else — no
vendor envelope. Rendering that into OpenAI's `{"type": "function", ...}`
wrapper, Anthropic's `input_schema`, or a text protocol is the adapter's
job, so supporting a new provider costs a few lines in your adapter and
zero changes in the runtime.

## Architecture

```
Registry ──▶ Projection ──▶ LLM ──▶ Validate ──▶ Authorize ──▶ Execute ──▶ Record ──▶ Continue/Wait/Complete
(capabilities)  (render)   (decide)              (Policy)      (Runtime)   (Ledger)
```

| Component | Responsibility |
|---|---|
| **Registry** | Versioned `Capability` ledger: dotted names (`filesystem.file.read`), JSON schema, declared effects, retry safety, categories, epochs, external `ToolProvider`s |
| **Projection** | Ordered sections (`fixed` / `append` / `epoch` / `volatile`) rendered into the per-turn prompt; window budget includes native tool schemas and reserved output tokens |
| **PolicyEngine** | The sole owner of execution permission — layered `absolute > admin > developer > workspace > session > llm`; a higher layer's `deny` can never be relaxed by a lower one |
| **Runtime** | Schema validation & self-repair, in-order execution (only adjacent read-only calls run concurrently), retry-safety-gated retries, `unknown` outcome on timeout, output-size artifacts |
| **Run** | The state machine: `RUNNING / WAITING_FOR_APPROVAL / WAITING_FOR_USER / COMPLETED / FAILED / CANCELLED` |
| **EventLedger** | Append-only log of everything that happened; `Session`/`Run` state is *derived* from it, never the other way around |
| **ArtifactStore** | Large results live outside the context, referenced as `{"$artifact": "art_..."}` — never a bare string, so ordinary data can never be misread as a reference |
| **WorkingState** | Structured goal / facts / decisions(+reasons) / open questions / next actions — compaction *merges* into it instead of re-summarizing prose |

## Capability awareness in layers

With hundreds of registered capabilities, per-turn overhead stays small
instead of preloading every full spec:

| Layer | What | Cost |
|---|---|---|
| 0 | Pinned capabilities — full spec resident in the kernel | opt-in |
| 1 | TOC — category names + counts, epoch-cached | ≤100 tk |
| 2 | Auto candidates — vector+BM25+tag search, top-k cards injected each turn | ~300 tk |
| 3 | `meta.tool.find` — the model searches the registry itself (fallback) | +1 loop |

Every registered capability stays reachable even with vectors disabled.

## Install

```yaml
dependencies:
  state_projection_loop:
    path: ../State-Projection-Agent-Loop-Dart   # or a git/pub dependency
```

**There are no runtime dependencies at all.** JSON Schema validation is a
self-contained mini validator, and the one hash the runtime needs (FNV-1a,
shared byte for byte with the Python port) is a dozen lines in
`lib/src/hashing.dart`.

### Platforms

The core runs everywhere Dart runs, web included: nothing under `lib/src/`
imports `dart:io` except the conditional filesystem implementation behind
`lib/src/fs.dart`. File-backed persistence (`JsonlLedger`, an `ArtifactStore`
with a `directory`, a `JsonlMemoryStore` with a path) throws
`UnsupportedError` where there is no filesystem; leave those unset and
everything stays in memory.

The parts that genuinely need an operating system — on-disk skills and
the filesystem/shell toolkit — are not in the main library. Import them separately, on native platforms only:

```dart
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:state_projection_loop/native.dart'; // VM / Flutter only
```

## Differences from the Python original

This port has **no Dart equivalent of Python's runtime introspection**
(`inspect`, `typing.get_type_hints`, `importlib`). Concretely:

- There is no `@capability` decorator / `build_capability_from_function`.
  Every `Capability` is built explicitly via `Capability.fromDict(definition,
  handler: ..., wantsCtx: true)` — a plain `Map<String, Object?>` definition
  (JSON Schema parameters, effects, retry safety, ...) plus an explicit
  handler function and an explicit `wantsCtx` flag, instead of being derived
  from a Python function's signature and docstring.
- Handler dispatch is direct (`handler:` a Dart `Function`), not resolved
  from a `"module.attr"` string via dynamic import.
- The package exposes a single async API (`Future<...>`) throughout — Dart
  has no equivalent of blocking on `asyncio.run()` from sync code, so there
  is no separate `send`/`asend` pair; just `await session.send(...)`.

Everything else — the Event Ledger, Projection pipeline, PolicyEngine,
Runtime execution guarantees, Run state machine, ArtifactStore, WorkingState,
compaction contract, and Session loop — is a faithful behavioral port.

## Quickstart

```dart
import 'package:state_projection_loop/state_projection_loop.dart';

Future<void> main() async {
  final registry = Registry();
  registry.register(
    {
      'name': 'inventory.stock.get',
      'category': 'inventory',
      'spec': {
        'description': '倉庫の在庫数を返す。',
        'parameters': {
          'type': 'object',
          'properties': {
            'warehouse': {'type': 'string', 'description': '倉庫名(例: 東京, 大阪)'},
          },
          'required': ['warehouse'],
        },
      },
      'discovery': {'embedding_text': '在庫 いくつ 残り stock'},
      'execution': {'retry_safety': 'pure'},
      'effects': [
        {'kind': 'none'},
      ],
    },
    handler: (Map<String, Object?> args) => {
      'warehouse': args['warehouse'],
      'stock': 42,
    },
  );

  final llm = ScriptedLLM([
    CallbackStep((messages, tools) =>
        ScriptedLLM.call('inventory.stock.get', arguments: {'warehouse': '東京'})),
    DecisionStep(ScriptedLLM.finish({'stock': 42})),
  ]);

  final session = Session(
    llm,
    kernel: 'あなたは在庫管理アシスタント。答えたら finish(result) を呼ぶ。',
    registry: registry,
    config: Config(mode: 'job'),
  );
  print(await session.runJob('東京倉庫の在庫はいくつ?'));
}
```

## Execution correctness the runtime guarantees

- **Order**: calls execute in the model's stated order by default. Only a
  contiguous run of capabilities that declare no write/external effect may
  execute concurrently — a write never jumps ahead of an earlier read, and a
  capability that forgets to declare its effects is treated as the most
  restrictive kind, not the safest.
- **Idempotency**: a capability may only be auto-retried if `retrySafety` is
  `pure` or `idempotent` — declaring `retries > 0` otherwise is a
  construction-time error. A timeout is recorded as outcome `unknown`, never
  silently `failed`: the runtime cannot know whether the underlying effect
  completed after it gave up waiting, and collapsing that distinction is
  exactly what lets non-idempotent operations double-fire.
- **Completion**: `finish(result)` is a formal property of the model's
  decision, not a capability routed through the runtime — a decision that
  combines `finish` with other tool calls is rejected outright, nothing in
  it executes.
- **Concurrency**: at most one turn in flight per `Session`; a second
  concurrent `send`/`runJob`/`resume`/`invoke` raises `ConcurrencyError`
  immediately instead of interleaving state.
- **Self-repair**: invalid arguments are *not executed*; the model receives
  the validation error plus the full spec as an observation and retries.
  `requireSpec: true` forces a spec review before a dangerous capability's
  first use.
- **Artifacts**: results above `maxInlineTokens` are stored outside the
  context and projected as a preview card, referenced as
  `{"$artifact": "art_..."}`. A bare string that happens to equal an
  artifact id is never resolved — only the structured reference form is.

## Policy: the LLM proposes, code decides

```dart
final policy = PolicyEngine(defaultDecision: 'require_approval');
policy.applyPreset('auto_safe');          // effect-free calls + workspace reads run automatically
policy.setScope('network_access', 'deny', layer: 'admin');   // a lower layer can never relax this
policy.addRule('workspace', Rule(decision: 'allow', capabilityPattern: 'fs.*'));

final session = Session(llm, policy: policy);
var result = await session.send('...');
if (session.run.state == 'WAITING_FOR_APPROVAL') {
  session.resolveApproval('approved');   // or 'denied'
  result = await session.resume();
}
```

Evaluation order is fixed: `absolute > admin > developer > workspace > session > llm`.
The most restrictive matching rule wins across layers — a `deny` at any
layer can never be relaxed by one below it. Within a layer the first
matching rule wins, except that a rule matching everything (a preset's
closing `require_approval`) is that layer's fallback, so a grant added after
`applyPreset` takes effect instead of being shadowed by it. An LLM-proposed safety
assessment (`policy.setLlmSafetyMode('advisory' | 'approval_routing')`) can
escalate toward approval but can never grant a bare `allow` or issue the
final `deny` by itself.

## Resumable runs

A `WAITING_FOR_APPROVAL` run survives a process restart:

```dart
// process 1
final session = Session(llm, config: Config.fromDict(
    {'mode': 'job', 'persistence': {'ledger_directory': './runs'}}));
await session.runJob('delete the old backups');
final runId = session.run.id;   // paused: WAITING_FOR_APPROVAL

// process 2 (hours later, no reference to the first Session)
final restored = Session.resumeFromLedger(llm, runId, config: cfg, kernel: kernel, registry: registry);
restored.resolveApproval('approved');
final result = await restored.resume();
```

Every projection, decision, policy verdict, command start/outcome, approval,
and run-state change is an `Event` in the append-only ledger
(`InMemoryLedger` by default, `JsonlLedger` when `persistence.ledgerDirectory`
is set). `Session` state is a *derived* view of that ledger, recoverable from
Events + a periodic `Snapshot`.

## Rewinding without losing history

```dart
final (branch, irreversible) = session.branch(atMessage: 6);
```

Past events are never deleted or mutated — `branch()` starts a new `Run`
that shares conversation/working-state up to the cut point. `irreversible`
lists effects the parent run already committed (anything with a declared
`external` effect) that the branch cannot undo — a sent email or a git push
stays sent/pushed regardless of which branch you're on now.

## Testing

```bash
dart pub get
dart analyze
dart test
```

## Bundled tools: packs on, names off

Bundled tools come in **packs** (`meta`, `checklist`, `state`, `spawn`); a bare
`Session(llm)` installs `meta` + `checklist`:

```dart
Session(llm, builtins: ['meta', 'state']);   // no checklist, with state tools
Session(llm, builtins: []);                  // nothing bundled
installBuiltins(registry, ['spawn']);       // same operation on your own registry
```

`installBuiltins` is idempotent and a name the registry already resolves is
left alone, so your own definition wins; an unknown pack name throws. Any
**pinned** capability may carry `discovery.kernel_note`, one sentence shown
under "[Runtime notes]" while it is reachable — the bundled tools use it and
so can yours. Per-tool control is the deny-list, for bundled and developer
capabilities alike:

```dart
final registry = Registry(disabled: ['planning.checklist.manage', 'debug/*']);
final session = Session(llm, registry: registry);

session.registry.disable(['my.dangerous.tool']);   // mid-session, e.g. per sub-agent
session.registry.enable(['my.dangerous.tool']);
```

Entries match a capability name, a category, or a category prefix
(`"cat/*"`) — the same rule `subset()` uses, so `subset()` is the allow-list
and `disable()` the deny-list.

A disabled capability is gone from **every** surface the model can see: the
native tool schemas, the pinned specs and runtime notes in the kernel, the
tool index, layer-2 candidates, `meta.tool.find`, and execution (it fails as
`unknown_capability`). Both `Registry.capabilities` and `Registry.get()` skip
disabled entries and everything else derives from those two, so there is no
surface left to leak through. The deny-list is by *name*, not by registered
object, so installing a pack again cannot bring a denied tool back.

Sections are asked to `shrink` from last to first when the window overflows,
so section order is also priority; custom sections extend `Section` and go in
via `Session(sections: ...)` or `session.addSection(...)`.

## Standard agent features (each one is a switch)

| Feature | Switch | What it does |
|---|---|---|
| Clarifying questions | pack `ask` | `meta.user.ask(question, choices?)` pauses the run in `WAITING_FOR_USER`; `send()`/`runJob()` return a `PendingQuestion`, the host calls `session.answer(text)` then `session.resume()`. The pause survives a restart like an approval does. |
| Loop guard | `limits.max_repeats` (3; `0` off) | An identical call that failed identically, or returned the same result, `max_repeats` times within the last `limits.repeat_window` (8) calls is not executed again. Pure reads may still be polled. |
| Structured job output | `result_schema` | In job mode `finish(result)` is validated against the JSON Schema and bounced back on failure. |
| Observers | `Session(onEvent: fn)` | Fires after every ledger append; read-only, a throwing observer is ignored. |
| Compression | `compression.*` (always on) | History renders in tiers by distance from a verbatim point that moves in steps, so the prompt prefix stays byte-identical between steps (prompt caches hit); old tool results are masked to one line unless they failed, the user's words are never touched. See [docs/compression.md](docs/compression.md). |
| Compaction | `compaction.trigger_ratio` (`0` off) | One extra model call folds the history before the verbatim point into `WorkingState` as a schema-validated, grounding-checked JSON delta (`state_folded` keeps the pre-fold state). |
| Skills | `skillCapability(name, text, summary: ...)` | A skill is a capability `skill.<name>.load`, so it rides the TOC, candidates and `meta.tool.find`. |
| Toolkits | `installToolkits(registry, root, shell: true)` (via `native.dart`) | Root-confined `filesystem.file.*` and `shell.command.run`; never installed unless you ask. |

```dart
final session = Session(llm, builtins: ['meta', 'checklist', 'ask'], onEvent: print,
    config: Config.fromDict({'compaction': {'trigger_ratio': 0.8}}));
session.registry.register(skillCapability('deploy', deploySteps, summary: 'How to deploy'));
installToolkits(session.registry, './workspace'); // needs native.dart

var reply = await session.send('Release the service');
if (session.run.state == 'WAITING_FOR_USER') {
  session.answer(await askTheUser((reply as PendingQuestion).text));
  reply = await session.resume();
}
```

Cross-session memory is specified but not built; see [docs/roadmap.md](docs/roadmap.md).

## Live check

`example/deepseek_live.dart` is a dart:io OpenAI-compatible adapter and a live
end-to-end check: `LLM_API_KEY=... dart run example/deepseek_live.dart`
(`DEEPSEEK_API_KEY` is read when `LLM_API_KEY` is unset).
