# Temporal Pattern Catalog: selection reference

Source: temporal-sa/temporal-design-patterns (`docs/<pattern>.md`, snapshot 2026-07-17). Each entry lists **Use when**, **Avoid when**, **Trade-offs** and **Instead consider**. Java code for each pattern is in `java-patterns.md`.

## Contents
1. Task Orchestration: Child Workflows, Parallel Execution, Pick First
2. Workflow Messaging: Signal with Start, Request-Response via Updates, Event Accumulator
3. Entity & Lifecycle: Entity Workflow, Continue-As-New, Updatable Timer
4. External Interaction: Polling, Long Running Activity, Delayed Start, Delayed Callback, Approval
5. Distributed Transaction: Saga, Early Return
6. Error Handling & Retry: seven patterns and a decision tree
7. Batch Processing: Fan-Out, Batch Iterator, Sliding Window, MapReduce Tree
8. QoS & Throughput: Downstream Rate Limiting, Priority, Fairness
9. Performance & Latency: Local Activities, Early Return + LA, Eager Workflow Start
10. Worker Configuration: Worker-Specific Task Queues, Activity Dependency Injection
11. Common combinations

---

## 1. Task Orchestration

### Child Workflows
- **Use when:** you need any of the following:
  - a separate Workflow ID for tracking or querying,
  - an operation that can outlive the parent (`ParentClosePolicy.PARENT_CLOSE_POLICY_ABANDON`),
  - logic reused by several parents,
  - a different Task Queue,
  - a separate history limit,
  - Workflow-level timeouts or retries.
- **Avoid when:** you only want to organize code, which language modules do better. Also avoid them to save cost: a child adds events, and on Cloud it is billed as 2 actions. The rule is: *when in doubt, use an Activity*.
- **Trade-offs:** more moving parts. The child's details aren't in the parent's history. Starting a child costs more than starting an Activity. Treat more than about 1,000 children per parent as a smell, not a hard limit, and note that starting hundreds at once can be slow.
- **Instead consider:** an Activity; a separate Workflow plus Signals.
- **Notes:** the parent and child share no memory, so they communicate only through Signals. Review the parent close policy.

### Parallel Execution
- **Use when:** you have independent items or service calls, fan-out/fan-in, or pipeline stages that can run in parallel.
- **Avoid when:** the steps depend on each other, need strict ordering, or there is only one fast operation.
- **Trade-offs:** throughput goes up, but you can overwhelm downstream services without a bound. Each pending Activity counts toward the 2,000 limit, and history grows quickly.
- **Mechanics:** start each call with `Async.function` or `Async.procedure`, collect the `Promise` objects, then `Promise.allOf(...).get()`. Bound concurrency with a semaphore-style loop, or use the batch patterns.

### Pick First (Race)
- **Use when:** you are choosing between a primary and a backup source, competing algorithms, or a fallback with a timeout.
- **Avoid when:** you need every result, the Activities have side effects that must not be cancelled, or order matters.
- **Trade-offs:** the losers may have done partial work. They see the cancellation only at their next heartbeat, so set a `HeartbeatTimeout` and heartbeat often.
- **Mechanics:** start the Activities inside `Workflow.newCancellationScope`, take `Promise.anyOf(...)`, then call `scope.cancel()`.

---

## 2. Workflow Messaging

| Need | Primitive | Response | Notes |
| :--- | :--- | :--- | :--- |
| Fire-and-forget event | Signal | none | Lowest overhead. Possible duplicates, so make handlers idempotent |
| Event, and start the Workflow if it is absent | Signal-with-Start | none | Atomic; safe to retry |
| Validated change with a result | Update (+ validator) | typed, sync | Written to history; rejected Updates aren't. 10 in flight / 2,000 total |
| Start and get a result | Update-with-Start | typed, sync | The basis of Early Return |
| Read-only | Query | typed, sync | Never change state; needs a running Worker |

### Signal with Start
- **Use when:** you are building entity Workflows (cart, account, session), consuming from Kafka or a queue, or creating Workflows lazily on the first event.
- **Avoid when:** it is a one-time operation (use `REJECT_DUPLICATE` instead) or the caller needs confirmation (use Update-with-Start).
- **Trade-offs:** the sender gets no confirmation that the Signal was processed. Keep a set of processed operation IDs for idempotency. Plan Continue-As-New because the Workflow has no natural end.
- **Reuse policies:**
  - `ALLOW_DUPLICATE` (the default) and `ALLOW_DUPLICATE_FAILED_ONLY` suit entities.
  - `REJECT_DUPLICATE` suits one-time operations.
  - Use `TERMINATE_IF_RUNNING` with care.

### Request-Response via Updates
- **Use when:** the caller needs confirmation, the input must be validated before it is accepted, or you need a typed synchronous state change.
- **Avoid when:** the message is fire-and-forget (use a Signal), the call is read-only (use a Query), or the rate is high (Updates are slower than Signals).
- **Trade-offs:** each Update writes to history and runs in a Workflow Task. Arguments and results count against the 2 MB payload limit. A validator can't change state.
- **Java note:** calling Activities from an Update handler works in the other SDKs. In Java, keep handlers light because each handler runs on its own Workflow thread.

### Event Accumulator
- **Use when:** many events for the same key arrive from many producers, or from one consumer of a mixed topic, and can be processed together in batches.
- **Avoid when:** every event must be processed individually in strict order, or events for different keys must be correlated with each other.
- **Mechanics:** Signal-with-Start into a collector Workflow (ID = group key). Buffer the events. Flush to one Activity when the inactivity timeout fires or a flush Signal arrives. Use Continue-As-New to bound history.
- **Trade-offs:** latency is added on purpose. The timeout value balances latency against batch size.

---

## 3. Entity & Lifecycle

### Entity Workflow
- **Use when:** you are modeling accounts, devices, subscriptions, carts, financial accounts or multi-tenant resources.
- **Avoid when:** the process is short-lived, the operations are stateless, the entity is only CRUD (a database is enough), or the message rate per entity is high. Keep it to single digits per second sustained; see the limits file.
- **Benefits:** changes to one entity are serialized with no locks, history is an audit trail, and Queries read state.
- **Trade-offs:** Continue-As-New is mandatory. Throughput is limited to one execution per entity. Keep large data in external stores. Consider the cost of millions of open Workflows.

### Continue-As-New
- **Use when:** a Workflow runs indefinitely or periodically, processes a stream, loops many times, or approaches the history thresholds.
- **Avoid when:** the Workflow is short-lived (under about 1,000 events) or must keep its full history for audit.
- **Checklist before calling it:**
  - wait for `Workflow.isEveryHandlerFinished()`,
  - make sure no Activities are pending,
  - pass state forward as Workflow input,
  - recompute the remaining timer durations,
  - remember that children not started with ABANDON will be closed.
- **Trigger:** `Workflow.getInfo().isContinueAsNewSuggested()`, or your own operation or event count.
- **Trade-offs:** Queries see only the current run, and debugging spans several runs. A Cron Workflow must not call Continue-As-New.

### Updatable Timer
- **Use when:** you need a deadline that can be extended, an SLA with a grace period, a postponable escalation, an auction close, or a payment grace period.
- **Avoid when:** the delay is fixed (use `Workflow.sleep`), you only need cancellation (use `CancellationScope`), or the schedule is recurring (use Schedules).
- **Mechanics:** store the deadline as an *absolute* epoch time. Loop on `Workflow.await(remaining, () -> deadlineChanged)`.

---

## 4. External Interaction

| Situation | Pattern |
| :--- | :--- |
| Webhook arrives and the Workflow may or may not exist | Signal-with-Start from the webhook handler (stable business Workflow ID) |
| Send a callback after a delay (≥1 s, up to years) | `Workflow.sleep` followed by an Activity |
| Submit a job and wait for its completion callback | Async Activity completion (task token + `doNotCompleteOnReturn`) |
| No callback; need results in about a second | Frequent polling inside a heartbeating Activity |
| No callback; minutes to days is fine | Infrequent polling through a retry policy (interval ≥ 1 min, `BackoffCoefficient` 1.0) |
| Multi-step polling with changing parameters | Periodic sequence: a Child Workflow + Continue-As-New |
| Task takes minutes to hours | Long Running Activity with heartbeats |
| A person decides | Approval |
| Start a single run later | Delayed Start (`setStartDelay`) |

### Polling
- Don't build a polling loop out of Workflow timers. Each iteration adds history events, and the catalog lists it as an approach to avoid.
- **Infrequent polling:** the Activity throws while the resource isn't ready, and the retry policy becomes the poll schedule. History stays minimal.

### Long Running Activity
- **Use when:** the Activity runs longer than about 30 s. Examples are file transfers, migrations, ML training and encoding.
- **Rules:**
  - use a short `HeartbeatTimeout`,
  - heartbeat often (the SDK throttles heartbeats),
  - put the progress checkpoint in the heartbeat details,
  - on retry, resume from `getHeartbeatDetails`.

  Cancellation reaches only an Activity that heartbeats.
- **Trade-offs:** you must write checkpoint logic and handle re-running the last checkpoint idempotently. Heartbeat details have a size limit.
- For tasks that run for months, combine heartbeats, a Signal back to the Workflow, and async completion.

### Delayed Start
- **Use when:** you need a one-time future run, such as a reminder in 24 h, a 7-day cancellation grace period, or a trial expiry.
- **Avoid when:** the run is recurring (use Schedules), the delay must change (use an Updatable Timer), or the delay is under a second.
- **Notes:** the Workflow is visible and can be cancelled during the delay. Signal-with-Start or Update-with-Start skips the remaining delay; a plain Signal doesn't. A start delay doesn't work with Schedules or Cron.
- **Schedule vs timer:** use a timer for a relative delay inside an execution. Use a Schedule for a calendar time or a recurring run. Don't use a Schedule with a single run to get a delayed start.

### Delayed Callback (Webhooks)
- **Trade-offs:** the webhook receiver needs a Temporal client. Task tokens must be stored durably outside Temporal. Workflow IDs must be deterministic, derived from the order or user ID.
- **Compared with a queue, DLQ, or cron+Redis:** Temporal gives durable timers, built-in retries, and visibility in the UI.

### Approval
- **Use when:** you have purchase orders, expenses, deployment gates, compliance reviews or access requests.
- **Mechanics:** a Signal carries the decision with approver, reason and timestamp. The Workflow calls `Workflow.await(timeout, () -> decision != null)` and takes the fallback or escalation path on timeout. Expose the status through a Query.
- **Variant:** use an Update with a validator when the approver's interface must confirm that the decision was accepted and valid.

---

## 5. Distributed Transaction

### Saga
- **Use when:** you need consistency across services or databases, two-phase commit isn't available, every step can be compensated, and eventual consistency is acceptable.
- **Avoid when:** you need strict ACID, a single service could use a local transaction, a step can't be compensated, or the operation must appear atomic to observers.
- **Rules:**
  - Register each compensation **before** running its step, so that a step that times out but actually succeeded is still undone.
  - Compensations must be idempotent and retried until they succeed.
  - Compensations run in reverse order, or in parallel if you choose.
- **Trade-offs:** other processes can see intermediate states, and compensation logic must be maintained alongside the forward logic.

### Early Return
- **Use when:** the client needs fast feedback, such as a payment authorization, an onboarding ID, or provisioning validation, and the slow work can continue in the background. Initialization should take under about 5 s.
- **Mechanics:** Update-with-Start. The Update handler waits for the init phase to finish and returns its result, or throws if init failed. The main method runs the slow phase or the cancel path.
- **Avoid when:** no intermediate feedback is needed, the work can't be split into phases, or the caller wants fire-and-forget.
- **Trade-offs:** the 10-in-flight-Update limit applies. The client must track completion separately. With Local Activities, initialization must fit in one Workflow Task.

---

## 6. Error Handling & Retry

**Defaults:** retries are unlimited with exponential backoff: `InitialInterval` 1 s, `BackoffCoefficient` 2.0, `MaximumInterval` 100 × initial, and no non-retryable types. `ScheduleToCloseTimeout` belongs on ActivityOptions, not in the retry policy, and it caps all attempts together.

**Decision tree**
1. Does each attempt cost money or quota? → **Fixed Count of Retries** (`setMaximumAttempts`).
2. Can retrying never succeed?
   - If a human can fix the input → **Resumable Activity**: park the Workflow and wait for a corrective Signal.
   - Otherwise → **Non-Retryable Errors** (`setDoNotRetry(...)` or `ApplicationFailure.newNonRetryableFailure`).
3. Does the error say when to retry (`Retry-After`, a maintenance end time)? → **Delayed Retry**: set `nextRetryDelay` on that failure.
4. Must the work finish within a business SLA? → **Fixed Wall-Time Retries** (`setScheduleToCloseTimeout`).
5. Do you want quick recovery and also patient waiting through outages? → **Fast/Slow Retries**: a bounded fast policy, then a long-interval unlimited policy.
6. Are retries unbounded? Add **Retry Alerting via Metrics**: emit a counter when `getAttempt()` passes a threshold.

Combine these with a Saga to compensate when retries finally give up.

---

## 7. Batch Processing

| Pattern | Records | Concurrency | Rate control | Mechanism |
| :--- | :--- | :--- | :--- | :--- |
| Single Workflow | ≤ a few hundred | Activities in sequence or parallel | No | One Activity per record |
| Fan-Out with Child Workflows | ≤ ~4M | Fixed: one child per chunk (pass offset + length) | No | Chunks of ≤500 records per child |
| Batch Iterator | Unlimited | One page per run | Yes: fixed page rate | Process a page, then Continue-As-New with the next offset |
| Sliding Window | Unlimited | Bounded window of children | Yes: window size | Each child Signals the parent when done; the parent starts the next; Continue-As-New |
| MapReduce Tree | Unlimited | Recursive, fully parallel | No: maximum speed | Split recursively; results Signalled up the tree |

- Pass offsets, IDs or object-store references to children, never the records themselves.
- Use Schedules for recurring jobs. Choose the overlap policy (default Skip) and add jitter.
- Use CLI batch operations (`temporal workflow signal|terminate --query ...`) for bulk changes to Workflows.

---

## 8. QoS & Throughput

| Approach | Where it is enforced | Across Workers | Use |
| :--- | :--- | :--- | :--- |
| `setMaxTaskQueueActivitiesPerSecond` | Server (matching) | Yes; set the same value on every Worker | Downstream RPS limit |
| `setMaxWorkerActivitiesPerSecond` | Each Worker process | No | Protect one host |
| `setMaxConcurrentActivityExecutionSize` (and the WFT and LA equivalents) | Worker slots | No | Concurrency, not throughput |
| Priority key 1–5 (1 is highest, 3 is the default) | Server | Yes | Urgent ahead of bulk; may starve low levels |
| Fairness key + weight | Server | Yes | Tenants share capacity in proportion. On Cloud it is enabled per Namespace and paid |
| A Task Queue + Worker pool per tier or tenant | Deployment | Hard isolation | Static; idle capacity isn't shared |

- **Downstream Rate Limiting:** send only the throttled Activity types to a dedicated Task Queue served by a dedicated Worker. If the cap is set too low, the queue backs up.
- **Priority:** set it on Workflow, Activity or Child Workflow options. Activities inherit their Workflow's priority.
- **Fairness:** applies within one priority level. Weights apply when a task is scheduled, not when it is dispatched. Accuracy drops with a very large number of keys.
- Without Priority and Fairness, there is no FIFO guarantee across executions.

---

## 9. Performance & Latency

Approximate figures for a three-Activity Workflow on Cloud, from the catalog benchmark:

| Option | First response | Total |
| :--- | :--- | :--- |
| Regular Activities | ~850 ms | ~850 ms |
| Early Return | ~265 ms | ~850 ms |
| Local Activities | ~275 ms | ~275 ms |
| Early Return + LA | ~160 ms | ~275 ms |
| Eager Start + LA (Go, Java, Python) | ~160–265 ms (the sources disagree) | ~265 ms |

- **Local Activities:** suit work of milliseconds to a few seconds *including retries*, that is idempotent and on a hot path. They have no heartbeat, no Task Queue rate limiting or routing, and use `ScheduleToCloseTimeout`. A failure re-runs the Workflow Task. Long retry backoffs cancel out the benefit.
- **Eager Workflow Start:** the starter and Worker share a process and client (`setDisableEagerExecution(false)`). Otherwise it falls back to normal dispatch. Self-hosted servers may need `system.enableEagerWorkflowStart=true`.
- Choose **Early Return + LA** when first-response time matters, and **LA (+ Eager)** when total time matters.

---

## 10. Worker Configuration

### Worker-Specific Task Queues
- **Use when:** a download → process → upload sequence must stay on one host, you have GPUs, you need to keep a session or connection, or you need elevated access.
- **Avoid when:** the Activities are stateless, or the data is in shared storage (S3, a database).
- **Mechanics:** every Worker polls a shared queue and also a unique host queue. The first Activity returns the host queue name. Later stubs use `setTaskQueue(hostQueue)` and `setScheduleToStartTimeout(...)` so the Workflow can recover if the host dies. Plan cleanup. Go also has Sessions.

### Activity Dependency Injection
- Build clients and pools once when the Worker starts and pass them into the Activity implementation's constructor. Register the Activity as an instance. In tests, register mocks instead.
- Shared dependencies must be thread-safe. If an Activity needs per-execution isolation, such as a database transaction, handle it inside the Activity.

---

## 11. Common combinations

| Scenario | Patterns |
| :--- | :--- |
| Checkout / payment | Early Return (Update-with-Start) + LA validation + Saga + Non-Retryable for validation errors + Fixed Count for paid gateways |
| Account / subscription | Entity Workflow + Signal-with-Start / Updates / Queries + Continue-As-New + Updatable Timer |
| Webhook integration | Signal-with-Start inbound + async completion + Delayed Retry (429) + outbound timer callbacks |
| Nightly bulk sync | Schedule + Sliding Window / Batch Iterator + Downstream Rate Limiting + Retry Metrics |
| Multi-tenant SaaS | Fairness (tenant key) + Priority (interactive = 1) + Activity DI |
| Human exception handling | Resumable Activity / Approval + Updatable Timer escalation |
| Kafka event aggregation | Event Accumulator (Signal-with-Start keyed by group) + Continue-As-New |
| ML / GPU pipeline | Worker-Specific Task Queue + Long Running Activity heartbeats + Child Workflows per stage |
