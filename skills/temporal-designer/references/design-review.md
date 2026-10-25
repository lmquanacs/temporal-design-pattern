# Design Review and Design Sessions

Use this to review a Temporal design or codebase, or to run a design session with a customer. Report findings as **Blocker** (wrong or won't scale), **Risk** (likely to cause incidents), or **Suggestion** (an improvement). Each finding gives the evidence, the consequence, and the fix.

## Session preparation

Ask the team for:

1. a description of the use case and the business process,
2. a Workflow diagram showing Activities, Signals and children,
3. Workflow histories from the Temporal UI, if code already runs,
4. the code, if they are willing to share it.

**Goals:** confirm correct use of the primitives, answer design questions, flag problems in advance, and build confidence for production. **Not goals:** deciding whether Temporal fits the business, debugging production (open a support ticket), or reaching a perfect design in one session.

## Discovery questions

- How much Temporal experience does the team have? Is this their first Workflow?
- Walk through the diagram:
  - What is the business process, and where does Temporal fit?
  - What starts the Workflow: a user, an event, or a schedule?
  - What is the peak volume?
  - How long does it run?
  - How many steps are there, and are they sequential or parallel?
  - Are the Activities too granular or too broad?
- **Fit check.** Watch for:
  - extreme low latency (millisecond trading),
  - synchronous read-only queries,
  - big data flowing through Workflows.

## Checklist

### Workflows
- [ ] Determinism is understood; non-determinism errors and replay tests are in place.
- [ ] Event History growth is bounded with Continue-As-New or children. Work is partitioned *across* Workflows rather than piled into one.
- [ ] The Workflow ID is a meaningful business key, and the reuse or conflict policy is intentional. Nothing uses the Run ID in logic, and IDs aren't reused at high frequency.
- [ ] Workflow execution and run timeouts are left at their defaults; business deadlines use timers.
- [ ] Failure semantics are understood: an `ApplicationFailure` fails the Workflow, and other exceptions retry the Workflow Task.
- [ ] There is no Workflow retry policy unless there is a clear reason.

### Child Workflows
- [ ] Each child has a strategic reason: partitioning, a different Task Queue or host, or team ownership. Children aren't used to organize code or save cost.
- [ ] A parent starts fewer than about 1,000 children, or uses a batch pattern.
- [ ] Shared state goes only through Signals.
- [ ] The parent close policy has been reviewed.

### Activities
- [ ] Activities are idempotent, using idempotency keys.
- [ ] Each Activity has its own `StartToCloseTimeout`, longer than its normal duration, with shorter client timeouts inside.
- [ ] `ScheduleToStartTimeout` is unset unless the queue is host-specific.
- [ ] Activities longer than about 30 s heartbeat with progress details and a short heartbeat timeout. Activities that must be cancellable heartbeat.
- [ ] Inputs and outputs are well under 2 MB, ideally references, and compression is on.
- [ ] Polling uses the frequent or infrequent pattern, not a timer loop; or use a Signal or async completion instead.
- [ ] No Activity listens on a port.
- [ ] Each Activity's retry policy matches its failure class, using the retry decision tree in `pattern-catalog.md`.
- [ ] Local Activities are used only for short, idempotent, hot-path work.
- [ ] The number of Activities is sensible: one Activity is the unit of retry, timeout and visibility.

### Signals, Queries and Updates
- [ ] Handlers are deterministic and idempotent, and change state only. Signal handlers don't call Activities.
- [ ] The code checks Signal send errors (Workflow not found, Workflow closed).
- [ ] The Signal rate is within guidance (about 5/s per execution), and the lifetime total is under 10,000 per run with a Continue-As-New cadence.
- [ ] Queries are read-only. Nothing exports state elsewhere that a Query could provide.
- [ ] Update validators are present where input can be invalid; remember rejected Updates aren't recorded.
- [ ] Update limits (10 in flight, 2,000 total) are respected.
- [ ] Before Continue-As-New, the code waits for `Workflow.isEveryHandlerFinished()`.

### Workers and Task Queues
- [ ] There are at least 2 Workers, with identical registrations per Task Queue.
- [ ] Every extra Task Queue is justified: a deployment unit, rate limiting, host routing, or priority.
- [ ] Rate limits are configured correctly: `maxTaskQueueActivitiesPerSecond` has the same value on every Worker; slots aren't treated as throughput limits.
- [ ] No ordering is assumed across executions; Priority and Fairness are used where needed.
- [ ] Workers are tuned: slots, pollers, and CPU/GC are monitored.

### Timers, Schedules and Cron
- [ ] No timer is shorter than 1 s.
- [ ] Schedules have a count, jitter, actions per second checked against the Namespace limit, an explicit overlap policy (default Skip), and backfill limits considered.
- [ ] No single-run Schedule is used for a delayed start; use Start Delay or a timer.
- [ ] Cron is replaced by Schedules.

### Data, visibility and security
- [ ] A custom Data Converter or codec is used for compression or encryption, with key rotation. The latency it adds to Workflow Tasks is measured.
- [ ] Datetime and duration serialization is consistent across languages.
- [ ] Search Attributes are for operations only, hold no personal data, and are understood to be eventually consistent. Memos and visibility APIs are treated as eventually consistent.
- [ ] Secrets (mTLS, API keys) are kept out of code and payloads.

### Versioning and operations
- [ ] There is a versioning strategy: Worker Versioning for short Workflows, or patching with `Workflow.getVersion` and a date to remove patches. Long Workflows rely on Continue-As-New to move to new code.
- [ ] Code changes are replay-tested.
- [ ] Interceptors, if used, are documented, since they can cause surprising behavior.
- [ ] There are alerts for schedule-to-start latency, Workflow Task latency, failures, and retry-attempt counters.

## Anti-patterns → fixes

| Anti-pattern | Why it hurts | Fix |
| :--- | :--- | :--- |
| DIY state in a database, plus status polling | Duplicates Temporal's durable state; race conditions | Entity Workflow + Queries (keep the database for reporting) |
| Kafka or RabbitMQ choreography between your own components | Hard to trace and compensate | Orchestrate with Workflows; Signal-with-Start at the edge |
| Child Workflow per function, for code organization | Extra events, actions and cost | Activities and language modules |
| Local Activities everywhere | Lose heartbeats, routing and rate limits; Workflow Task retries | Regular Activities by default |
| Timer-loop polling in Workflow code | History grows | Infrequent polling through a retry policy, or a heartbeating Activity |
| Unbounded `Async` fan-out | 2,000 limit; downstream overload | A bounded window or a batch pattern |
| A single entity Workflow receiving a flood of Signals | Lock contention; Continue-As-New starves; termination | Shard, accumulate, or move ingestion upstream |
| Business logic on Search Attributes | Eventually consistent; not encrypted | Queries or an external store |
| The same timeouts and retries for every Activity | Wrong failure behavior | Tune each Activity per its failure class |
| Unlimited retries with no alerting | Silent stuck Workflows | Retry Alerting via Metrics, or Fixed Wall-Time |
| Retrying validation errors | Waste of time and money | Non-Retryable Errors |
| Large payloads through history | 2 MB / 50 MB limits; slow replay | References, external storage, compression |
| Listener or server inside an Activity | Not durable; blocks slots | An external listener that calls Signal-with-Start |
| Workflow execution timeout used as a business deadline | Hard kill, no cleanup | A timer inside the Workflow plus a compensation path |

## Review output template

```markdown
### Summary
<one paragraph: fit, overall health, top 3 actions>

### Findings
| Sev | Area | Evidence | Consequence | Fix |
| Blocker | History | OrderWorkflowImpl.java:88 loops forever, no CAN | terminated at 51,200 events | Continue-As-New when isContinueAsNewSuggested() |

### Limits arithmetic
<from limits-and-guardrails.md worksheet>

### Open questions
```
