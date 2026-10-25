# Configuration Best Practices: Timeouts, Retries, Workers, Clients

This file collects all configuration guidance in one place, with Java examples. The values below are **starting points to tune with metrics, not rules**. Method names follow temporal-sdk 1.27; newer tuning APIs are marked "check SDK version".

## Contents
1. Principles
2. Activity timeouts
3. Retry policy design
4. Starting values by Activity type
5. Local Activities
6. Heartbeats and throttling
7. Child Workflows
8. Workflow-level settings
9. Compensation (Saga) Activities
10. Client-side settings
11. Worker tuning
12. Externalizing configuration safely
13. Configuration review checklist

---

## 1. Principles

1. **Configure each Activity separately.** Choose its timeouts and retries from its own duration and failure modes. One shared setting for every Activity is a review finding.
2. **Retry by default, stop on purpose.** Temporal's default is unlimited retries. Add limits only for cost (attempt count), an SLA (`ScheduleToClose`), or permanent errors (non-retryable types).
3. **Detect failures with the shortest timeout that is still safe.** A long `StartToClose` with no heartbeat means a crashed Worker isn't noticed until that timeout expires.
4. **Client timeouts inside the Activity are shorter than the Activity timeout.** Otherwise Temporal retries while the original call is still running, which produces duplicate side effects.
5. **The Workflow doesn't time out; the business process does.** Express deadlines with timers in Workflow code.
6. **Every unbounded retry gets an alert.**

## 2. Activity timeouts

| Timeout | Measures | Default | Set it? | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `StartToClose` | One attempt | none | **Always** (strongly recommended) | Resets on every retry. Make it longer than the slowest normal attempt (for example p99 × 2) |
| `ScheduleToClose` | All attempts, including queue time and backoff | ∞ | When an SLA or budget exists | Doesn't reset. Either this or `StartToClose` is required |
| `ScheduleToStart` | Time spent queued before a Worker picks it up | ∞ | **Rarely.** Only for host-specific queues, or when the Workflow must react to "no Worker available" | A `ScheduleToStart` timeout is not retried. Monitor `temporal_activity_schedule_to_start_latency` instead |
| `Heartbeat` | Gap between heartbeats | none | For any Activity longer than about 30 s, or one that must be cancellable | Detects a dead Worker quickly. Cancellation is delivered only on a heartbeat |

```java
ActivityOptions.newBuilder()
    .setStartToCloseTimeout(Duration.ofSeconds(30))
    .setScheduleToCloseTimeout(Duration.ofMinutes(10))   // optional SLA
    .setHeartbeatTimeout(Duration.ofSeconds(20))         // long-running only
    .build();
```

Timeouts are enforced by the server. When one expires, the Worker's thread may still be running, so make the Activity code honor its own deadlines.

## 3. Retry policy design

| Field | Default | How to choose |
| :--- | :--- | :--- |
| `InitialInterval` | 1 s | The typical recovery time of a transient fault. Use 1 s for in-cluster services and 5–30 s for third parties |
| `BackoffCoefficient` | 2.0 | Use 2.0 for general backoff. Use **1.0** for a fixed interval (polling, the slow phase of Fast/Slow) |
| `MaximumInterval` | 100 × `InitialInterval` | Cap it at the longest gap you will tolerate between attempts (often 1–10 min). It also bounds the time to recover once the dependency is back |
| `MaximumAttempts` | 0 (unlimited) | Set it only for paid or quota-consuming calls, or when a human or another path takes over |
| `DoNotRetry` / non-retryable types | none | Validation, not-found, authorization and business-rule errors |

```java
RetryOptions.newBuilder()
    .setInitialInterval(Duration.ofSeconds(1))
    .setBackoffCoefficient(2.0)
    .setMaximumInterval(Duration.ofMinutes(2))
    .setDoNotRetry("ValidationError", "NotFoundError", "UnauthorizedError")
    .build();
```

**Work out the retry timeline before you ship.** With 1 s, ×2 and a 2 min cap, the waits are 1, 2, 4, 8, 16, 32, 64 s, then 120 s from then on. That is about 2 minutes until the gaps reach the cap, and 1 retry every 2 minutes after that.

**How errors map to behavior:**
- *Transient errors* (timeouts, 5xx, connection reset): let them throw, and they are retried.
- *Permanent errors:* throw `ApplicationFailure.newNonRetryableFailure(msg, "Type")`, or list the type in `setDoNotRetry`.
- *The server says when to retry* (429 with `Retry-After`): throw `ApplicationFailure.newFailureWithCauseAndDelay(msg, "RateLimited", cause, delay)`.
- *An input a human can correct:* use non-retryable plus the Resumable Activity pattern.

Wrap third-party exceptions in typed `ApplicationFailure` types so that `DoNotRetry` matches stable type names, not vendor exception classes.

## 4. Starting values by Activity type

| Activity type | StartToClose | ScheduleToClose | Heartbeat | Retry |
| :--- | :--- | :--- | :--- | :--- |
| Fast internal call (database write, internal API) | 5–10 s | — | — | Defaults, `MaximumInterval` 1 min |
| External HTTP or SaaS API | 30 s (client timeout 20 s) | Optional SLA | — | `InitialInterval` 2–5 s, `MaximumInterval` 5 min, non-retryable 4xx types |
| Paid or quota API (payments, LLM) | 30–60 s | Optional | — | `MaximumAttempts` 3–5, non-retryable business declines |
| SLA-bound call ("charge within 2 min") | 10–20 s | **= SLA** | — | Defaults |
| Long job (file, ETL, ML) | Longest normal duration + margin (hours) | Optional | **10–60 s**, with progress details | Defaults; resume from the heartbeat |
| Infrequent poll (minutes to days) | 10–30 s | Optional overall deadline | — | `InitialInterval` = poll period (≥1 min), `BackoffCoefficient` 1.0 |
| Frequent poll (about 1 s, inside the Activity) | Minutes to hours | Optional | 5–10 s | Defaults |
| Async completion (waits for a webhook) | Longest expected wait | Optional | Optional (if the external side heartbeats) | Usually `MaximumAttempts` 1–3, since resubmitting has side effects |
| Host-pinned (worker-specific queue) | Per step | — | If long | Defaults, **plus `ScheduleToStart` 30 s–5 min** to detect a dead host |
| Rate-limited downstream | Per call | — | — | Delayed Retry on 429; the queue's rate limit does the pacing |
| Compensation | 10–30 s | — | — | **Unlimited**, `MaximumInterval` ≤ 5 min (see §9) |

## 5. Local Activities

```java
LocalActivityOptions.newBuilder()
    .setScheduleToCloseTimeout(Duration.ofSeconds(5))   // total, including retries — always set
    .setStartToCloseTimeout(Duration.ofSeconds(2))      // per attempt (optional)
    .setLocalRetryThreshold(Duration.ofSeconds(10))     // beyond this backoff, retry via a server timer
    .setRetryOptions(RetryOptions.newBuilder().setMaximumAttempts(3).build())
    .build();
```

- Keep the total time (including retries) to a few seconds and well under the Workflow Task timeout, which defaults to 10 s.
- **A long backoff cancels out the benefit.** Retries that wait longer than the local retry threshold become server timers, adding round trips and history events. If an Activity needs patient retries, make it a regular Activity.
- A Local Activity can't heartbeat or be rate limited, and it always runs on the Workflow Worker.

## 6. Heartbeats and throttling

- The SDK **throttles** heartbeats. Calling `heartbeat()` in a tight loop is safe because only some calls are sent. In Java the throttle interval defaults to 80% of the heartbeat timeout, falling back to `WorkerOptions.setDefaultHeartbeatThrottleInterval` (30 s) when no timeout is set, with an upper bound of `setMaxHeartbeatThrottleInterval` (60 s). Check these defaults for your SDK version.
- **Choosing the heartbeat timeout:** at least 2–3 × the gap between your heartbeat calls, so a slow chunk of work doesn't time out.
- **Heartbeat details:** keep them small. Store a checkpoint such as an offset or cursor, not data. Read them back with `getHeartbeatDetails(...)` on retry.
- **Cancellation** reaches the Activity only through a heartbeat call, which throws `ActivityCanceledException` (or `ActivityCompletionException`). Catch it, clean up, and rethrow.
- Set `ActivityOptions.setCancellationType(...)` when the Workflow must wait for the Activity's cleanup (`WAIT_CANCELLATION_COMPLETED`). The default is `TRY_CANCEL`.

## 7. Child Workflows

```java
ChildWorkflowOptions.newBuilder()
    .setWorkflowId("shipment-" + orderId)                 // deterministic business ID
    .setTaskQueue("shipping")
    .setParentClosePolicy(ParentClosePolicy.PARENT_CLOSE_POLICY_TERMINATE)  // default; ABANDON / REQUEST_CANCEL
    .setCancellationType(ChildWorkflowCancellationType.WAIT_CANCELLATION_COMPLETED)
    // .setWorkflowExecutionTimeout(...)  // generally leave unset, as for top-level Workflows
    // .setRetryOptions(...)              // generally not recommended; retry the Activities inside
    .build();
```

- Choose the **parent close policy** deliberately:
  - `TERMINATE` (the default) for helpers that are part of the parent,
  - `ABANDON` for work that must outlive the parent (fire-and-forget, Sliding Window, children that survive Continue-As-New),
  - `REQUEST_CANCEL` for cooperative cleanup.
- With `ABANDON`, wait for `Workflow.getWorkflowExecution(child).get()` before the parent completes or continues as new, so the child has actually started.
- Leave child execution and run timeouts unset. Put deadlines in Workflow code.

## 8. Workflow-level settings

| Setting | Default | Guidance |
| :--- | :--- | :--- |
| Workflow Execution Timeout | ∞ | Leave unset. It kills the Workflow with no cleanup; use a timer plus a compensation path |
| Workflow Run Timeout | ∞ | Leave unset |
| Workflow Task Timeout | 10 s (max 120 s) | Raise it only for heavy data converters or codecs, or very large histories. Find the root cause first: CPU saturation, inputs over 4 MB, or results over 2 MB |
| Workflow retry policy | none | Not recommended. A Workflow shouldn't fail because of transient faults; Activities absorb them |
| Workflow ID reuse policy | `ALLOW_DUPLICATE` | `REJECT_DUPLICATE` for one-time operations; `ALLOW_DUPLICATE_FAILED_ONLY` to allow restarts only after failures |
| Workflow ID conflict policy | `FAIL` | `USE_EXISTING` for idempotent starts or Update-with-Start onto an existing entity |
| Start delay | none | One-time delayed start. Doesn't work with Schedules or Cron |
| Priority / Fairness | priority 3 | See `pattern-catalog.md` §8 |

```java
WorkflowOptions.newBuilder()
    .setWorkflowId("order-" + orderId)
    .setTaskQueue("orders")
    .setWorkflowIdReusePolicy(WorkflowIdReusePolicy.WORKFLOW_ID_REUSE_POLICY_ALLOW_DUPLICATE_FAILED_ONLY)
    .setWorkflowIdConflictPolicy(WorkflowIdConflictPolicy.WORKFLOW_ID_CONFLICT_POLICY_FAIL)
    .build();
```

A deadline expressed in Workflow code instead of an execution timeout:

```java
CancellationScope work = Workflow.newCancellationScope(() -> process(order));
Promise<Void> deadline = Workflow.newTimer(Duration.ofHours(24));
Promise<Void> done = Async.procedure(work::run);
Promise.anyOf(done, deadline).get();
if (!done.isCompleted()) { work.cancel(); compensate(order); }
```

## 9. Compensation (Saga) Activities

- Retry compensations **without limit**, with a capped `MaximumInterval` (1–5 min). A compensation that gives up leaves the system inconsistent.
- Make them idempotent, and make them tolerate undoing a step that never happened, because compensations are registered before their step runs.
- Give them their own stub with their own options, not the forward steps' options. For example, a forward step might use `MaximumAttempts(3)`, but its compensation must not.
- Alert on compensation attempts (Retry Alerting via Metrics). A stuck compensation needs a human.
- Use `Saga.Options.setContinueWithError(true)` if the remaining compensations should still run after one fails.

```java
PaymentActivities compensations = Workflow.newActivityStub(PaymentActivities.class,
    ActivityOptions.newBuilder()
        .setStartToCloseTimeout(Duration.ofSeconds(30))
        .setRetryOptions(RetryOptions.newBuilder()
            .setInitialInterval(Duration.ofSeconds(2))
            .setMaximumInterval(Duration.ofMinutes(5))   // unlimited attempts
            .build())
        .build());
```

## 10. Client-side settings

```java
WorkflowServiceStubsOptions.newBuilder()
    .setTarget(target)
    .setRpcTimeout(Duration.ofSeconds(10))          // default per-RPC deadline
    .build();
```

- **Starting a Workflow or sending a Signal:** an RPC can fail with `UNAVAILABLE` after the SDK's internal retries, so retry at the application edge too. This is safe because the Workflow ID makes starts idempotent and handlers deduplicate Signals by operation ID.
- **Waiting for a result:** don't block forever. Use `WorkflowStub.getResult(timeout, unit, Class)`, or for Updates `handle.getResultAsync(timeout, unit)`.
- **Updates:** use `UpdateOptions.setWaitForStage(WorkflowUpdateStage.ACCEPTED)` to return once the validator has accepted the Update, or `COMPLETED` to wait for the handler's result. An Update must reach a Worker, so a client deadline guards against Worker outages.
- **Signal errors:** handle `WorkflowNotFoundException` (the Workflow is closed or never existed). Use Signal-with-Start when "create if missing" is the intent.
- Reuse **one** `WorkflowClient` per process. It is thread-safe and holds the gRPC connection.

## 11. Worker tuning

```java
WorkerFactory factory = WorkerFactory.newInstance(client,
    WorkerFactoryOptions.newBuilder()
        .setWorkflowCacheSize(600)              // sticky cache: cached executions (default 600)
        .setMaxWorkflowThreadCount(600)         // threads for cached workflows (default 600)
        .build());

Worker worker = factory.newWorker("orders", WorkerOptions.newBuilder()
    .setMaxConcurrentActivityExecutionSize(200)        // activity slots (default 200)
    .setMaxConcurrentWorkflowTaskExecutionSize(200)    // workflow task slots (default 200)
    .setMaxConcurrentLocalActivityExecutionSize(200)   // local activity slots (default 200)
    .setMaxConcurrentActivityTaskPollers(5)            // pollers (default 5)
    .setMaxConcurrentWorkflowTaskPollers(5)
    // .setMaxWorkerActivitiesPerSecond(50)            // per-process throughput cap
    // .setMaxTaskQueueActivitiesPerSecond(20)         // server-enforced queue cap; same value on every Worker
    .build());
```

- **Size slots to downstream resources, not CPU alone.** Activity slots should be no more than the database connection pool or HTTP client limit. Too many slots means Activities time out waiting for connections.
- **Signals that a Worker needs tuning:**
  - High `temporal_activity_schedule_to_start_latency` or `temporal_workflow_task_schedule_to_start_latency` → more Workers, slots or pollers.
  - High `temporal_workflow_task_execution_latency` → CPU, GC or a slow codec.
  - Sticky cache evictions or replay-heavy behavior → a bigger cache or more memory.
- **Resource-based tuning:** newer SDKs offer `WorkerOptions.setWorkerTuner(...)` (resource-based slot suppliers) and autoscaling pollers. Check your SDK version before recommending them.
- **Separate Worker pools** for Workflow Tasks and for heavy or special Activities, such as GPU work or rate-limited queues, so a slow Activity can't starve Workflow Tasks.
- **Run at least 2 Workers per Task Queue**, each with identical registrations.
- **Graceful shutdown:** call `factory.shutdown()` and then `factory.awaitTermination(timeout, unit)` so in-flight Activities finish. Make the deployment's termination grace period longer than that timeout. An Activity interrupted in the middle retries after its heartbeat or StartToClose timeout.

## 12. Externalizing configuration safely

Workflow code must not read environment variables, files or config services directly, because that is nondeterministic. Inject configuration at **registration time** or through **Workflow input**:

```java
// Worker bootstrap — values come from env / Spring properties / config server
ActivityOptions defaults = ActivityOptions.newBuilder()
    .setStartToCloseTimeout(Duration.parse(cfg.get("activity.default.startToClose")))   // e.g. "PT30S"
    .build();
Map<String, ActivityOptions> perActivity = Map.of(
    "Charge", ActivityOptions.newBuilder()
        .setStartToCloseTimeout(Duration.ofSeconds(45))
        .setRetryOptions(RetryOptions.newBuilder().setMaximumAttempts(3).build())
        .build());

worker.registerWorkflowImplementationTypes(
    WorkflowImplementationOptions.newBuilder()
        .setDefaultActivityOptions(defaults)
        .setActivityOptions(perActivity)        // keyed by activity type name
        .build(),
    OrderWorkflowImpl.class);

// In the workflow, the stub can omit options to pick these up:
PaymentActivities payments = Workflow.newActivityStub(PaymentActivities.class);
```

- Changing timeout or retry values generally doesn't break replay, because only the command type and order are compared. Still, run a replay test before rolling out.
- Business parameters, such as an approval window or a batch page size, belong in **Workflow input**, carried forward across Continue-As-New. A value that varies per execution must never come from the Worker's environment.
- Spring Boot: `temporal-spring-boot-starter` binds connection, namespace and Worker settings from `spring.temporal.*` properties. Keep per-Activity options in typed `@ConfigurationProperties` and apply them as shown above.
- Keep secrets (mTLS keys, API keys) in a secret manager or environment variables, never in Workflow input or payloads.

## 13. Configuration review checklist

- [ ] Every Activity has an explicit `StartToClose`, sized to its own duration, and client timeouts inside are shorter.
- [ ] `ScheduleToClose` is used only for SLAs; `ScheduleToStart` only for host-pinned queues.
- [ ] Activities longer than about 30 s, and cancellable ones, heartbeat with a timeout of at least 2–3 × the heartbeat gap.
- [ ] Retry policies are chosen per failure class. Permanent errors are non-retryable, using typed `ApplicationFailure`.
- [ ] `MaximumAttempts` is set only where attempts cost money or quota, or where a fallback exists.
- [ ] `MaximumInterval` is capped where recovery time matters.
- [ ] Unbounded retries have an attempt-threshold alert.
- [ ] Local Activities total a few seconds including retries, and have no long backoff.
- [ ] Compensations retry without limit and have alerts.
- [ ] Workflow execution and run timeouts and the Workflow retry policy are unset; deadlines are timers.
- [ ] The Workflow ID reuse and conflict policies are intentional.
- [ ] Child Workflow parent close policies are explicit.
- [ ] Client calls have deadlines; result waits are bounded; starts and Signals are retried idempotently.
- [ ] Worker slots match downstream pool sizes. Schedule-to-start latency is monitored. Shutdown is graceful.
- [ ] Configuration is injected at registration time or through input, never read inside Workflow code. Changes are replay-tested.
