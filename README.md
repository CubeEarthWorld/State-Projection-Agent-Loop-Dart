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

The only runtime dependency is `package:crypto` (used for the deterministic
`HashingEmbedding`). JSON Schema validation is a self-contained mini
validator with no external dependency.

## Differences from the Python original

This port has **no Dart equivalent of Python's runtime introspection**
(`inspect`, `typing.get_type_hints`, `importlib`). Concretely:

- There is no `@capability` decorator / `build_capability_from_function`.
  Every `Capability` is built explicitly via `Capability.fromMap(definition,
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
layer can never be relaxed by one below it. An LLM-proposed safety
assessment (`policy.setLlmSafetyMode('advisory' | 'approval_routing')`) can
escalate toward approval but can never grant a bare `allow` or issue the
final `deny` by itself.

## Resumable runs

A `WAITING_FOR_APPROVAL` run survives a process restart:

```dart
// process 1
final session = Session(llm, config: Config.fromMap(
    {'mode': 'job', 'persistence': {'ledger_directory': './runs'}}));
await session.runJob('delete the old backups');
final runId = session.run.id;   // paused: WAITING_FOR_APPROVAL

// process 2 (hours later, no reference to the first Session)
final restored = Session.resumeFromLedger(llm, runId, config: cfg, registry: registry);
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
