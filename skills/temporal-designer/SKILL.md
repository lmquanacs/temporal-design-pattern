---
name: temporal-designer
description: Design, review and implement Temporal Workflow architectures as a solution architect, with Java as the default language. Use when the user asks to design a Temporal solution, pick or compare Temporal patterns (Saga, Entity Workflow, Signal-with-Start, Update / Update-with-Start / Early Return, Continue-As-New, Child Workflows, fan-out, polling, webhooks/async completion, approval, retries, batch processing, rate limiting, priority/fairness, Local Activities, Eager Start, worker-specific task queues), review a Workflow design or code for best practices, size against Temporal limits (history, pending activities, signals, updates, payloads), or write Java Temporal SDK code (io.temporal.*) for any of these. Also triggers on "temporal architecture", "workflow design review", "durable execution design", "which temporal pattern".
---

# Temporal Designer

Turn a business requirement into a Temporal design: pick the patterns, check the platform limits, produce a design document, and write Java code when asked. Use the same skill to review an existing design against the best-practices checklist.

Write in **Java** (Temporal Java SDK, `io.temporal.*`) unless the user names another language. If they do, keep the design and replace the snippets with that SDK's equivalents.

## Reference files (open only what the step needs)

| File | Open it when |
| :--- | :--- |
| `references/pattern-catalog.md` | Choosing patterns: 35 patterns in 10 categories, each with when to use, when not to, trade-offs and alternatives |
| `references/java-patterns.md` | Writing code: Java implementation for each pattern |
| `references/java-foundations.md` | Writing code: Worker setup, stubs, timeouts, retries, determinism, testing, versioning |
| `references/configuration.md` | Setting timeouts, retry policies, heartbeats, child, client or Worker options; starting values by Activity type; externalizing configuration |
| `references/limits-and-guardrails.md` | Sizing a design or answering "will this scale?" |
| `references/design-review.md` | Reviewing a design or code, or running a design session; includes anti-patterns |

## Workflow

### 1. Frame the requirement

Ask about, or infer and state, each of the following. Don't design until you can answer most of them.

- **Trigger:** a user action, a system event (Kafka, webhook), or a schedule.
- **Volume:** peak starts per second and records per run.
- **Duration:** seconds, hours, or open-ended (an entity).
- **Interaction:** does the caller need a synchronous result? Are there human steps? Inbound events?
- **External systems:** do they have rate limits, callbacks, or SLAs? Are they idempotent?
- **Consistency:** what must be undone when a step fails?
- **Latency target:** first-response time versus total completion time.
- **Tenancy and priority:** shared Workers, urgent work versus bulk work.

Check the fit early. Temporal is a *control plane*. Push back on these:

- hard latency requirements below about 100 ms,
- synchronous read-only lookups,
- bulk data flowing through Workflow payloads,
- per-entity message rates above single digits per second.

### 2. Decompose and select patterns

Map each concern to a category, then choose a pattern using `references/pattern-catalog.md`.

| Concern | Go-to pattern | Alternatives |
| :--- | :--- | :--- |
| Multi-service consistency | Saga | Early Return for a fast acknowledgement |
| Caller needs an immediate result | Update-with-Start (Early Return) | Update, Query |
| An event for an entity that may not exist yet | Signal-with-Start | Event Accumulator for bursts |
| A long-lived business object | Entity Workflow + Continue-As-New | Updatable Timer for deadlines |
| Wait for a person | Approval (Signal + timer) | Update with validator; Resumable Activity |
| Wait for an external system | Async completion / webhook Signal | Polling (frequent or infrequent) |
| Long task | Heartbeating Long Running Activity | Child Workflow |
| Large record sets | Sliding Window / Batch Iterator | Fan-Out children; MapReduce Tree |
| Downstream rate limit | Dedicated Task Queue + `maxTaskQueueActivitiesPerSecond` | Delayed Retry on 429 |
| Retry behavior | See the decision tree in the catalog | Fixed Count, Wall-Time, Non-Retryable, Fast/Slow, Metrics |
| Latency | Local Activities, Early Return + LA | Eager Workflow Start (co-located) |
| Host affinity | Worker-Specific Task Queue | Shared storage |
| Multi-tenant fairness | Fairness key + Priority key | A Task Queue per tier |

Apply these defaults unless there is a stated reason not to:

- **Activity over Child Workflow.** Add a child only for a separate ID or history, to outlive the parent, for reuse, or to target another Task Queue.
- **Regular Activity over Local Activity.** Use a Local Activity only for short (seconds including retries), idempotent work on a latency-critical path.
- **The Workflow ID is a business key**, with an explicit reuse or conflict policy.
- **Every Activity is idempotent** (use idempotency keys) and has an explicit `StartToCloseTimeout`. Take its retry and timeout values from the starting-values table in `references/configuration.md` §4.
- **Anything open-ended uses Continue-As-New.**
- **Pass references, not data**, for anything bigger than a few KB.

### 3. Check the limits

Open `references/limits-and-guardrails.md` and do the arithmetic for:

- events per run,
- concurrently pending Activities or children (keep under 500),
- Signals and Updates per execution, and the message rate,
- payload size (2 MB per request).

If a limit is reached, partition the work: Continue-As-New, children, or a batch pattern.

### 4. Produce the design

Unless the user asks for another format, use this structure:

```markdown
## <Solution name> — Temporal design
**Requirement summary** — trigger, volume, duration, latency, consistency
**Workflows** — table: Workflow type | Workflow ID scheme | Lifetime | Task Queue | Patterns applied
**Activities** — table: Activity | Idempotency key | StartToClose | Retry policy | Heartbeat | Task Queue
**Messaging** — Signals / Updates / Queries with handler semantics
**Sequence diagram** — Mermaid, followed by a numbered walkthrough
**Failure handling** — retry strategy per failure class, compensations, human escalation
**Scale & limits** — the arithmetic from step 3
**Workers & deployment** — Task Queues, Worker pools, rate limits, priority/fairness, versioning approach
**Observability** — metrics/alerts (retry attempts, schedule-to-start latency), Search Attributes (ops only)
**Open questions / assumptions**
```

### 5. Implement (when asked)

Use `references/java-foundations.md` for the skeleton and `references/java-patterns.md` for each pattern. Rules for Java code:

- **Workflow code is deterministic.** Use `Workflow.currentTimeMillis()`, `Workflow.sleep` / `Workflow.newTimer`, `Workflow.randomUUID()`, `Async.function` and `Promise`. Never use `Thread`, `System.currentTimeMillis()`, `UUID.randomUUID()`, I/O or static mutable state.
- Interfaces use `@WorkflowInterface`, `@WorkflowMethod`, `@SignalMethod`, `@UpdateMethod`, `@UpdateValidatorMethod`, `@QueryMethod`, `@ActivityInterface` and `@ActivityMethod`.
- Handlers change state only. The `@WorkflowMethod` reacts to the state through `Workflow.await(...)`.
- Before `Workflow.continueAsNew`, wait for `Workflow.isEveryHandlerFinished()`.
- Activities receive their dependencies through the constructor and register as instances.
- Include a `TestWorkflowEnvironment` test, and a replay test when changing existing Workflow code.

### 6. Review (when asked)

Follow `references/design-review.md`. Report findings as **Blocker / Risk / Suggestion**. Each finding gives the evidence (a file and line, or a design element), the consequence, and the fix (a pattern or code change).

## Guardrails

- Don't present an inference as fact. When a limit or feature status is version-sensitive, say which SDK or server version you assumed, and suggest checking https://docs.temporal.io/cloud/limits.
- Don't claim "exactly-once" for Activities. They are at-least-once; recommend idempotency instead.
- Present latency figures as approximate benchmarks and recommend measuring.
- Fairness on Temporal Cloud must be turned on per Namespace and is a paid feature. Say so when you recommend it.
- Eager Workflow Start isn't available in the TypeScript SDK. It needs the starter and the Worker in the same process.
