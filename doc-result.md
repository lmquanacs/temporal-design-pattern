# doc-result.md — Evidence pack for `temporal-design-patterns.md`

Paths are relative to `tmp/temporal-design-patterns/` (clone of `https://github.com/temporal-sa/temporal-design-patterns`, depth 1, commit `66d067801970f302a928d1e8ee0a64e02ddf8bd4`, 2026-07-17) unless prefixed otherwise.

## Objective

- **Topic:** Temporal design patterns, researched from a solution architect's point of view.
- **Document type:** a selection and reference guide (Deep tier, because it covers the whole catalog).
- **Audience:** solution architects and senior engineers who design or review Temporal applications.
- **Reader goal:** pick the right pattern or combination for a requirement, know the trade-offs and the platform limits, and run a design review.
- **Scope:** all 45 pattern pages, the 10 category overviews, and the SA Design & Best Practices Guide. Per-language implementation detail, the docs site, and the sandbox runner are not covered.

## Map

| Path | Role |
| :--- | :--- |
| `CLAUDE.md` | Repo instructions: VitePress site, style guide, commands |
| `CONTRIBUTING.md` | Required pattern page structure, banned words, sidebar categories |
| `README.md` | Overview, live runner, deployment |
| `docs/.vitepress/config.mts` | **Source of truth** for categories and pattern membership (sidebar) |
| `docs/index.md` | Landing page with pattern tiles |
| `docs/*-patterns.md` (10 files) | Category overviews with a "Choosing a Pattern" section |
| `docs/<pattern>.md` (35 files) | Pattern pages: Overview, Problem, Solution, When to use, Trade-offs, Comparison, Pitfalls |
| `Design & Best Practices Guide.md` | SA design-session runbook and best-practices checklist |
| `batch_workflow_design_best_practices.md` | Older batch guide, superseded by `docs/batch-processing-patterns.md` |
| `sandbox-runner/patterns/*/pattern.json` | Runnable samples for each language (19 patterns) |
| `sandbox-runner/src/manager.ts` | Sandbox images and the Temporal dev server |
| `todo.md` | Maintainers' backlog (versioning, anti-patterns, and more) |

## Public surface (exact syntax the guide and skill rely on)

- Sidebar entry format: `{ text: 'Your Pattern Name', link: '/your-pattern-name' }`, from `CONTRIBUTING.md:24`
- Commands: `npm install`, `npm run docs:dev`, `npm run docs:build`, `npm run docs:preview`, from `package.json` scripts and `CLAUDE.md:12-15`
- Retry defaults table (`MaximumAttempts`, `InitialInterval`, `BackoffCoefficient`, `MaximumInterval`, `NonRetryableErrorTypes`), from `docs/error-handling-patterns.md:117-123`
- Java APIs (all read in the files cited):
  - `new Saga(new Saga.Options.Builder().setParallelCompensation(false).build())`, `saga.addCompensation(...)`, `saga.compensate()`: `docs/saga-pattern.md:196-221`
  - `WorkflowClient.startUpdateWithStart(workflow::update, UpdateOptions.<T>newBuilder().build(), new WithStartWorkflowOperation<>(workflow::run, arg))` with `WorkflowIdConflictPolicy.WORKFLOW_ID_CONFLICT_POLICY_FAIL`: `docs/early-return.md:261-275`
  - `workflowClient.newSignalWithStartRequest()`, `request.add(...)`, `workflowClient.signalWithStart(request)`: `docs/signal-with-start.md:156-159`
  - `Workflow.getInfo().isContinueAsNewSuggested()`, `Workflow.continueAsNew(...)`: `docs/entity-workflow.md:301-307`
  - `Priority.newBuilder().setPriorityKey(1)`: `docs/priority-task-queues.md:75`
  - `.setFairnessKey("tenant-a").setFairnessWeight(2.0f)`: `docs/fairness.md:89-91`
  - `WorkerOptions.newBuilder().setMaxTaskQueueActivitiesPerSecond(5.0)`: `docs/downstream-rate-limiting.md:104-105`
  - `Workflow.newCancellationScope`, `Async.function`, `Promise.anyOf`, `scope.cancel()`: `docs/pick-first.md:139-153`
  - `context.getHeartbeatDetails(Integer.class)`, `context.heartbeat(...)`: `docs/long-running-activity.md:127,142`
  - `context.getTaskToken()`, `context.doNotCompleteOnReturn()`, `completionClient.complete(taskToken, result)`: `docs/delayed-callback.md:598-611`
  - `RetryOptions.newBuilder().setDoNotRetry("OrderNotFoundError", "ValidationError")`: `docs/non-retryable-errors.md:305`
  - `ApplicationFailure.newNonRetryableFailure(msg, type)`: `sandbox-runner/patterns/resumable-activity/java/src/main/java/TransferActivity.java:22`
  - `ApplicationFailure.newFailureWithCauseAndDelay(msg, type, null, Duration)`: `sandbox-runner/patterns/delayed-retry/java/src/main/java/RateLimitedActivity.java:30-34`
  - `ctx.getInfo().getAttempt()`, `ctx.getMetricsScope().counter(...).inc(1)`: `docs/retry-metrics.md:131-133,290-297`
  - `.setDisableEagerExecution(false)`: `sandbox-runner/patterns/eager-workflow-start/java/src/main/java/Main.java:31`
  - `.setStartDelay(Duration.ofHours(1))`: `docs/delayed-start.md:175`
- SDK versions pinned in the samples:
  - Java `temporal-sdk 1.27.0` (12 poms)
  - Go `go.temporal.io/sdk v1.32.1` (10)
  - Python `temporalio==1.9.0` (16)
  - TypeScript `@temporalio/* ^1.13.0` (15)
  - Sandbox images: `node:20`, `python3.12`, `golang:1.22`, `temurin:17` (`sandbox-runner/src/manager.ts:106-136`)

## Findings

### Catalog structure

- [verified] There are 10 categories and 35 patterns. The sidebar is the authoritative list: `docs/.vitepress/config.mts:22-118`
- [verified] Each category page has decision rules under "Choosing a Pattern", for example `docs/task-orchestration-patterns.md:40-46` and `docs/external-interaction-patterns.md:60-70`.
- [verified] Ordering of the Error Handling decision tree: `docs/error-handling-patterns.md:84-108`

### Orchestration

- [verified] Use a Child Workflow for a separate ID or history, to outlive the parent, for reuse, or to target a different Task Queue. Use an Activity otherwise: `docs/child-workflows.md:567-588`
- [verified] "When in doubt, use an Activity." Don't use Child Workflows for code organization or cost. On Cloud a child counts as 2 actions: `Design & Best Practices Guide.md:337-343`
- [verified] More than 1,000 children per parent is guidance, not a hard limit: `Design & Best Practices Guide.md:350-351`
- [verified] Pick First losers need heartbeats to see cancellation and may have done partial work: `docs/pick-first.md:470-473`

### Messaging

- [verified] Signal with Start is atomic and fire-and-forget. Handlers need operation-ID idempotency. Reuse policy guidance: `docs/signal-with-start.md:242-258`
- [verified] Updates are synchronous, validated, written to history, and slower than Signals. Limits are 10 in flight and 2,000 total: `docs/request-response-via-updates.md:240-254`
- [verified] Rejected Updates are not recorded in history: `Design & Best Practices Guide.md:545`
- [verified] Signal handlers shouldn't call Activities: `Design & Best Practices Guide.md:513`
- [verified] Signals may be delivered more than once: `Design & Best Practices Guide.md:492`

### Entities

- [verified] Entity Workflow fit and non-fit cases: `docs/entity-workflow.md:463-465`
- [verified] Continue-As-New caveats: timers are not carried over, children are closed unless ABANDON, wait for pending Activities, and wait for handlers to finish: `Design & Best Practices Guide.md:730-734`
- [verified] Updatable Timer uses absolute timestamps: `docs/updatable-timer.md:526`

### External interaction

- [verified] Polling variants and their thresholds; avoid a timer-based polling loop: `docs/polling.md:575-607`
- [verified] Don't run listeners inside Activities: `Design & Best Practices Guide.md:407-408`
- [verified] Webhook patterns 1–3 and the sub-second timer caution: `docs/delayed-callback.md:661-668`
- [verified] Async completion task tokens must be persisted outside Temporal: `docs/delayed-callback.md:683`
- [verified] Delayed Start uses no Worker resources during the delay and can't be changed afterwards: `docs/delayed-start.md:357-369`

### Transactions

- [verified] Register each Saga compensation before its step and run them in reverse: `docs/saga-pattern.md:205-221`
- [verified] Saga fit, non-fit and consistency trade-offs: `docs/saga-pattern.md:287-299`
- [verified] Early Return initialization should take under 5 s and is subject to the 10-Update limit: `docs/early-return.md:364,377`

### Retries and timeouts

- [verified] Activity timeouts: StartToClose is strongly recommended, ScheduleToStart is generally left unset, and one of StartToClose or ScheduleToClose is required: `Design & Best Practices Guide.md:412-417`
- [verified] Use timers for Workflow deadlines and avoid a Workflow retry policy: `Design & Best Practices Guide.md:316,326`
- [verified] Delayed Retry uses `nextRetryDelay` taken from the error: `docs/delayed-retry.md:10-23`

### Batch

- [verified] Batch selection table: `docs/batch-processing-patterns.md:7-13`
- [verified] Schedule overlap policy defaults to Skip; use jitter: `Design & Best Practices Guide.md:623,641`

### QoS

- [verified] Comparison of rate-limiting options: `docs/downstream-rate-limiting.md:222-233`
- [verified] Set the same `maxTaskQueueActivitiesPerSecond` on every Worker: `Design & Best Practices Guide.md:580-581`
- [verified] Priority 1–5 can starve lower levels: `docs/priority-task-queues.md:174`
- [verified] No ordering guarantee without Priority and Fairness: `Design & Best Practices Guide.md:587-590`

### Latency

- [verified] Latency figures: `docs/performance-latency-patterns.md:20-37`
- [verified] Local Activity limits: `docs/local-activities.md:150-169`
- [verified] Prefer regular Activities: `Design & Best Practices Guide.md:436-439`
- [verified] Eager Workflow Start needs co-location and isn't supported in TypeScript: `docs/eager-workflow-start.md:174-195`

### Workers

- [verified] Worker-Specific Task Queue trade-offs: `docs/worker-specific-taskqueue.md:663-677`
- [verified] Run at least 2 Workers with identical registrations: `Design & Best Practices Guide.md:560,564`
- [verified] Injected dependencies are shared and must be thread-safe: `docs/activity-dependency-injection.md:679`

### Fit and anti-patterns

- [verified] Temporal is a control plane. Watch for extreme low latency, synchronous reads, and DIY state management: `Design & Best Practices Guide.md:145-166`
- [verified] Search Attributes are for operations only, must not hold PII, and are eventually consistent: `Design & Best Practices Guide.md:689-695`

### External verification (fetched 2026-10-25)

- [verified] History limits: 51,200 events / 50 MB, warning at 10,240 / 10 MB. https://docs.temporal.io/cloud/limits
- [verified] "2,000 incomplete Activities, Signals, Child Workflows, or external Workflow Cancellation requests … additional Commands *of that type* will fail"; aim for 500 or fewer. Same URL.
- [verified] 10,000 Signals per execution; 10 in-flight and 2,000 total Updates; 2 MB per request; 4 MB per history transaction. Same URL.
- [verified] Priority range `[1,5]`, lower value means higher priority, default 3, enabled by default. Fairness is enabled per Namespace on Cloud with a UI toggle and is a paid feature. https://docs.temporal.io/develop/task-queue-priority-fairness

### Inferences

- [inferred] The 2,000 incomplete-command limit applies to each type separately, based on the wording "of that type". The guide says "of each type".

## Conflicts

| # | Sources | Conflict | Handling in the draft |
| :--- | :--- | :--- | :--- |
| 1 | `docs/child-workflows.md:7,593`, `docs/request-response-via-updates.md:253`, `docs/parallel-execution.md:474` ("50K"); `docs/batch-iterator.md:14`, `docs/fanout-child-workflows.md:14` ("50,000") vs `docs/batch-processing-patterns.md:144` and the Cloud docs ("51,200") | History event limit | Used 51,200 from the Cloud docs |
| 2 | `docs/batch-processing-patterns.md:143` says 2,000 is one combined count of unfinished actions; the Cloud docs say "of that type" | Combined vs per type | Used per type (inferred, see Open questions) |
| 3 | `docs/entity-workflow.md:465` (">100 per second per entity" is a poor fit) vs `Design & Best Practices Guide.md:479,497` (≤5 signals/sec sustained) | Message-rate threshold | Used the conservative single-digit guidance and recommended sharding or accumulation |
| 4 | `docs/performance-latency-patterns.md:36` (Eager + LA first response ~265 ms) vs `docs/early-return-local-activities.md:282` (~160 ms) | Benchmark numbers | Flagged in the guide; tell readers to measure |
| 5 | `docs/error-handling-patterns.md:93,105` (Delayed Retry = "fixed interval backoff" for maintenance windows) vs `docs/delayed-retry.md:10` and its tile `:44` (`nextRetryDelay` set per failure) | What Delayed Retry is | Followed the pattern page; the decision node reads "error says when to retry" |
| 6 | `docs/entity-workflow.md:474` ("exactly-once execution") and `docs/index.md:337` ("exactly-once processing") vs `Design & Best Practices Guide.md:370` (Activities are at-least-once) | Delivery guarantee | Left out "exactly-once"; the guide requires idempotent Activities |
| 7 | `Design & Best Practices Guide.md:630` (Start Delay is experimental and only in Go/Java/Python, "as of 2024-02-20") vs `docs/delayed-start.md:97,193` (TypeScript `startDelay` is shown) | Stale SDK support statement | Guide says "set the start delay option" without a support matrix |
| 8 | `Design & Best Practices Guide.md:711` ("Worker Versioning … pre-release, don't recommend yet") vs `docs/fairness.md:255` (treats Worker Versioning as current) | Version status | Guide lists Worker Versioning or patching as options and makes no status claim |
| 9 | `CLAUDE.md:7` (site on GitHub Pages at taonic.github.io) and `README.md:86` vs `README.md:13` (fly.dev) plus `fly.toml`/`Dockerfile` | Where the site is hosted | Not relevant to the reader; not used |
| 10 | `CLAUDE.md:68-75` sidebar table and `CONTRIBUTING.md:29-37` vs `config.mts` | Stale category lists (for example "Idempotent Distributed Transactions" doesn't exist) | Used `config.mts` |
| 11 | `CLAUDE.md:34,79,93` refers to `skills/validated-pattern-writing/` | That directory doesn't exist in the clone | Noted only |
| 12 | `CONTRIBUTING.md:43-56` requires "When to use / Comparison" sections | Batch and retry pattern pages (for example `docs/batch-iterator.md`, `docs/fixed-count-retries.md`) lack them | Took decision content for those from the category pages instead |
| 13 | `docs/entity-workflow.md:124` (`workflow.all_handlers_finished` passed as a callable) vs `:510` (`workflow.all_handlers_finished()`) | Python API spelling | Not used (the guide is language-neutral; the skill uses Java) |

## Open questions

- Does the 2,000 limit apply to each command type separately or in total? The Cloud docs imply per type but don't say so explicitly. Confirm with Temporal engineering or the server source.
- What is the right per-entity message-rate guidance (≤5/s vs >100/s)? This needs maintainers to agree.
- What are the current release status of Worker Versioning and TypeScript Start Delay? The fetched pages state no status.
- Which Eager + LA first-response figure is correct?
- Is `batch_workflow_design_best_practices.md` intended to be deleted now that `docs/batch-processing-patterns.md` exists? This isn't stated anywhere.
- Is `Design & Best Practices Guide.md` (internal Slack and Google Docs links) meant to be public? Its internal links were deliberately left out of the guide.
- The SA guide's "Suggested Session Outline" heading (`Design & Best Practices Guide.md:105`) is empty, so the intended session agenda is unknown.

## Validation

- `git clone --depth 1 …`: succeeded, commit `66d0678`.
- Checked that each claim in the guide traces to a cited line. External limits were fetched from docs.temporal.io (HTTP 200 for all four pages).
- **Not run:** `npm run docs:build` (the guide lives outside the VitePress site), the Java snippets in the skill (the samples were not executed), the Mermaid render, and the link checks on external URLs other than the four fetched pages.

## Derived artifact

- `skills/temporal-designer/` (SKILL.md + `references/pattern-catalog.md`, `java-patterns.md`, `java-foundations.md`, `configuration.md`, `limits-and-guardrails.md`, `design-review.md`) reuses the findings above with Java as the default language.
- `configuration.md`:
  - Its timeout and retry principles trace to `Design & Best Practices Guide.md:298-327,410-424,436-449` and `docs/error-handling-patterns.md:112-126`.
  - The starting-values table (§4), the throttle defaults, the Worker defaults, `setLocalRetryThreshold`, `setWorkerTuner`, the `WorkflowImplementationOptions.setActivityOptions` approach, and the Spring property prefix are **[assumed]** from SDK knowledge. They are not in the catalog and haven't been compiled. Check them against the target SDK version.
- Java snippets marked as taken from the catalog trace to the anchors in "Public surface". These are written from SDK knowledge and **not compiled**: the Fast/Slow, Updatable Timer, Approval, Event Accumulator, bounded Parallel, Sliding Window, Resumable and Worker-Specific snippets, and the test and replay code. Compile them against the target SDK version before shipping.

## Not included

- The sandbox runner and Daytona internals, and the VitePress theme.
- Per-language code (Go, Python and TypeScript are deliberately omitted; the skill prefers Java).
- Nexus, Interceptors, Data Converter and encryption detail, and Cron (deprecated in favor of Schedules) beyond one-line mentions.
- Internal Slack and Google Docs references from the SA guide.
- `todo.md` items: versioning patterns, outbox and DLQ anti-patterns.
