# Limits and Guardrails

These are the Temporal Cloud limits from https://docs.temporal.io/cloud/limits, checked on 2026-10-25. Self-hosted defaults can differ, and limits change between versions. When a design depends on a number, say so and re-check that page.

## Per Workflow Execution

| Limit | Value | Notes |
| :--- | :--- | :--- |
| Event History length | **51,200 events** or **50 MB** | Warns at 10,240 events or 10 MB. Cloud users don't see the server warning, so check `isContinueAsNewSuggested()` |
| Incomplete commands | **2,000** each for Activities, Signals sent, Child Workflows, and external cancel requests | Further commands *of that type* fail. Keep to **500 or fewer** for best performance |
| Signals received | **10,000** in total | After that, Signals are dropped. Entities must Continue-As-New |
| Updates | **10 in flight**, **2,000 in total** | Limits Early Return and Update-heavy entities |
| Payload | **2 MB** per request; **4 MB** per history transaction; 4 MB per gRPC message | Batching many Activity inputs into one Workflow Task can exceed 4 MB |
| Workflow Task timeout | 10 s default; 120 s maximum | Raise it only for heavy data converters or very large histories |
| Timer resolution | Don't rely on durations under 1 s | — |

## Rates (guidance)

- **Signals or Updates to one execution:** keep the sustained rate to about 5 per second or less. Each message locks the execution and writes to the database, so the theoretical ceiling is about 1 / DB latency (roughly 20/s at 50 ms). Continue-As-New needs a quiet window of about 100 ms with no unhandled Signals. If Signals keep arriving faster than that, Continue-As-New never runs, history keeps growing, and the execution is eventually terminated.
  - Mitigations: shard the entity, batch messages upstream, use an Event Accumulator per key, or send updates to an external store.
- **Children per parent:** about 1,000 is a design smell, not a hard limit. Starting hundreds at once can add delays of several minutes. Use Sliding Window or MapReduce Tree.
- **Schedules:** Cloud's default is 10 schedule actions per second per Namespace (raisable to 100 quickly; beyond that, ask Temporal engineering). Use jitter. Backfills can buffer up to about 1,000 executions.
- **Batch operations (CLI):** 1 running batch job per Namespace, at 50 Workflows per second.

## Sizing worksheet

Do this arithmetic for each Workflow type:

```
events_per_run   ≈ Σ(activities × ~3 events) + timers × 2 + signals + updates × 2 + children × ~3 + markers
                   (an Activity is scheduled/started/completed; a retry adds no events until it completes)
runs_needed      = ceil(total_events / safe_threshold)      # safe_threshold ≈ 10,000 → plan Continue-As-New
pending_peak     = max concurrent activities | children     # must be ≤ 500 target, < 2,000 hard
signals_lifetime = rate × lifetime                          # < 10,000 per run → otherwise CAN cadence
payload          = largest input/output                     # ≤ ~100 KB comfortable; > 2 MB impossible → pass references
```

If any line fails, partition the work: Continue-As-New, Child Workflows, or a batch pattern (Fan-Out ≤ ~4M records; Batch Iterator, Sliding Window or MapReduce Tree for unbounded sets).

## Hard rules

1. **Determinism.** Workflow code must replay identically. Test changes with `WorkflowReplayer`.
2. **At-least-once Activities.** An Activity runs exactly once only when it succeeds first time. Design every Activity to be idempotent, using business idempotency keys.
3. **Control plane, not data plane.** Keep bulk data out of payloads. Pass references, or use external storage. A Large Payload Codec adds a remote round trip to every payload, so apply it case by case.
4. **Signals can be duplicated.** Make handlers idempotent with operation IDs.
5. **Queries are read-only.** They need a live Worker, and they also work on closed Workflows.
6. **Search Attributes** are for operations only. They are not codec-encrypted, so keep personal data out, and they are eventually consistent.
7. **No FIFO across executions** unless you use Priority and Fairness. Within one execution, your code decides the order, and Signals arrive in the order received.
8. **Local Activities** run for seconds, including retries. They have no heartbeat, rate limit or routing.
9. **Sessions** exist only in Go. Use Worker-Specific Task Queues in Java.
10. **Side Effects:** if a side effect can fail, use an Activity instead.
11. **Cron Workflows** are a legacy feature; prefer Schedules. A Cron Workflow must not call Continue-As-New.

## Feature status checks before recommending

| Feature | Note |
| :--- | :--- |
| Fairness | On Cloud it is turned on per Namespace with a UI toggle and is a **paid** feature. Weights apply when a task is scheduled |
| Priority | Enabled by default on Cloud and self-hosted. Range 1–5, default 3 |
| Eager Workflow Start | Go, Java and Python only. Self-hosted may need `system.enableEagerWorkflowStart=true` |
| Worker Versioning | Check the current release status in the docs. The catalog's older SA guide called it pre-release |
| Start Delay | Doesn't work with Schedules or Cron. Check SDK support |
| Nexus | Use it for Workflow-to-Workflow calls across Namespaces. The older approach is a client inside an Activity |
