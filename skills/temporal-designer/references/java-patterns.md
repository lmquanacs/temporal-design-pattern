# Java Implementations for Each Pattern

These snippets follow the catalog's Java examples (temporal-sdk 1.27). They show the core of each pattern; imports and boilerplate are left out. The stubs, options and Worker setup they assume are in `java-foundations.md`. The snippets haven't been compiled as written, so adapt the names to the user's codebase.

## Contents
Saga · Early Return (Update-with-Start) · Signal-with-Start · Update with validator · Entity Workflow + Continue-As-New · Updatable Timer · Approval · Event Accumulator · Child Workflows · Parallel Execution (bounded) · Pick First · Long Running Activity · Polling · Async completion · Delayed Start · Retry patterns · Resumable Activity · Batch Iterator · Sliding Window · Downstream Rate Limiting · Priority & Fairness · Local Activities · Eager Workflow Start · Worker-Specific Task Queue

---

## Saga

```java
public class AccountWorkflowImpl implements AccountWorkflow {
  private final AccountActivities act = Workflow.newActivityStub(AccountActivities.class,
      ActivityOptions.newBuilder().setStartToCloseTimeout(Duration.ofSeconds(10)).build());

  @Override
  public String openAccount(OpenAccountRequest req) {
    Saga saga = new Saga(new Saga.Options.Builder().setParallelCompensation(false).build());
    try {
      act.createAccount(req);
      saga.addCompensation(act::clearPostalAddresses, req);   // register BEFORE the step
      act.addAddress(req);
      saga.addCompensation(act::removeClient, req);
      act.addClient(req);
      saga.addCompensation(act::disconnectBankAccounts, req);
      act.addBankAccount(req);
      return "Account " + req.accountId() + " opened";
    } catch (ActivityFailure e) {
      saga.compensate();                                      // runs in reverse order
      throw e;
    }
  }
}
```

Compensation Activities must be idempotent and must tolerate undoing a step that never actually happened.

## Early Return (Update-with-Start)

```java
public class TransactionWorkflowImpl implements TransactionWorkflow {
  private boolean initDone = false;
  private Transaction tx;
  private Exception initError;

  @Override
  public TxResult processTransaction(TransactionRequest req) {
    tx = localActs.mintTransactionId(req);
    try { tx = localActs.initTransaction(tx); }               // phase 1: fast, ideally Local Activities
    catch (Exception e) { initError = e; }
    finally { initDone = true; }

    if (initError != null) { acts.cancelTransaction(tx); return new TxResult("", "cancelled"); }
    acts.completeTransaction(tx);                             // phase 2: slow, in the background
    return new TxResult(tx.getId(), "completed");
  }

  @Override // @UpdateMethod
  public TxResult returnInitResult() {
    Workflow.await(() -> initDone);
    if (initError != null) throw Workflow.wrap(initError);
    return new TxResult(tx.getId(), "initialized");
  }
}

// Client
TransactionWorkflow wf = client.newWorkflowStub(TransactionWorkflow.class,
    WorkflowOptions.newBuilder()
        .setWorkflowId("transaction-" + txId)
        .setTaskQueue("transactions")
        .setWorkflowIdConflictPolicy(WorkflowIdConflictPolicy.WORKFLOW_ID_CONFLICT_POLICY_FAIL)
        .build());
WorkflowUpdateHandle<TxResult> h = WorkflowClient.startUpdateWithStart(
    wf::returnInitResult,
    UpdateOptions.<TxResult>newBuilder().build(),
    new WithStartWorkflowOperation<>(wf::processTransaction, req));
TxResult early = h.getResultAsync().get();
```

## Signal-with-Start

```java
ShoppingCartWorkflow wf = client.newWorkflowStub(ShoppingCartWorkflow.class,
    WorkflowOptions.newBuilder().setWorkflowId("cart-" + cartId).setTaskQueue("carts").build());
BatchRequest req = client.newSignalWithStartRequest();
req.add(wf::run);
req.add(wf::addItem, itemId, productId, qty);
client.signalWithStart(req);

// Handler: idempotent by operation id
@Override public void addItem(String itemId, String productId, int qty) {
  if (!processed.add(itemId)) return;
  items.add(new CartItem(productId, qty));
}
```

## Update with validator

```java
@UpdateValidatorMethod(updateName = "changeEmail")
public void validateChangeEmail(String email) {
  if (deleted) throw new IllegalStateException("account deleted");
  if (!email.contains("@")) throw new IllegalArgumentException("invalid email");
}

@UpdateMethod
public String changeEmail(String email) {   // runs only if the validator passed; written to history
  state.setEmail(email);
  return state.getEmail();
}

// Client: blocks until the handler returns
String result = stub.changeEmail("a@b.com");
```

## Entity Workflow + Continue-As-New

```java
public record AccountInput(String userId, Optional<UserState> state) {}

public class UserAccountWorkflowImpl implements UserAccountWorkflow {
  private UserState state = new UserState();
  private boolean deleted;

  @Override
  public void run(AccountInput in) {
    in.state().ifPresent(s -> this.state = s);
    Workflow.await(() -> deleted || Workflow.getInfo().isContinueAsNewSuggested());
    if (!deleted) {
      Workflow.await(Workflow::isEveryHandlerFinished);       // drain signal/update handlers
      Workflow.continueAsNew(new AccountInput(in.userId(), Optional.of(state)));
    }
  }
  @Override public void delete() { deleted = true; }          // @SignalMethod
  @Override public UserState getState() { return state; }     // @QueryMethod
}
```

## Updatable Timer

```java
private long deadlineMillis;      // absolute epoch ms
private boolean deadlineChanged;

@SignalMethod public void updateDeadline(long newDeadlineMillis) {
  deadlineMillis = newDeadlineMillis; deadlineChanged = true;
}

private void sleepUntilDeadline() {
  while (true) {
    long remaining = deadlineMillis - Workflow.currentTimeMillis();
    if (remaining <= 0) return;
    deadlineChanged = false;
    boolean changed = Workflow.await(Duration.ofMillis(remaining), () -> deadlineChanged);
    if (!changed) return;                                     // timer fired
  }
}
```

## Approval

```java
private ApprovalDecision decision;   // approver, approved, reason, timestamp

@SignalMethod public void submitDecision(ApprovalDecision d) { if (decision == null) decision = d; }
@QueryMethod  public String approvalStatus() {
  return decision == null ? "PENDING" : (decision.approved() ? "APPROVED" : "REJECTED");
}

@Override public Result run(Request r) {
  acts.notifyApprovers(r);
  boolean received = Workflow.await(Duration.ofDays(3), () -> decision != null);
  if (!received) { acts.escalate(r); return Result.timedOut(); }
  return decision.approved() ? acts.fulfil(r) : Result.rejected(decision.reason());
}
```

## Event Accumulator

```java
private final List<Event> buffer = new ArrayList<>();
private final Set<String> seen = new HashSet<>();
private boolean flushRequested;

@SignalMethod public void add(Event e) { if (seen.add(e.id())) buffer.add(e); }
@SignalMethod public void flush()      { flushRequested = true; }

@Override public void run(String groupKey, List<Event> carried) {
  buffer.addAll(carried);
  while (!flushRequested) {
    final int before = buffer.size();
    boolean active = Workflow.await(Duration.ofMinutes(5),
        () -> flushRequested || buffer.size() != before);
    if (!active) break;                                       // inactivity timeout
  }
  if (!buffer.isEmpty()) acts.processBatch(groupKey, List.copyOf(buffer));
  // To keep collecting with fresh history instead of completing:
  // Workflow.await(Workflow::isEveryHandlerFinished); Workflow.continueAsNew(groupKey, List.of());
}
// Producers: Signal-with-Start using Workflow ID = "acc-" + groupKey
```

## Child Workflows

```java
ChildWorkflowOptions opts = ChildWorkflowOptions.newBuilder()
    .setWorkflowId("shipment-" + orderId)
    .setTaskQueue("shipping")
    .setParentClosePolicy(ParentClosePolicy.PARENT_CLOSE_POLICY_ABANDON)   // only if it must outlive the parent
    .build();
ShipmentWorkflow child = Workflow.newChildWorkflowStub(ShipmentWorkflow.class, opts);
Promise<ShipResult> p = Async.function(child::ship, order);
Workflow.getWorkflowExecution(child).get();   // child has started (required before CAN/completing with ABANDON)
ShipResult r = p.get();
```

## Parallel Execution (bounded)

```java
List<Promise<Result>> inFlight = new ArrayList<>();
List<Result> results = new ArrayList<>();
int maxConcurrent = 50;
for (Item item : items) {
  if (inFlight.size() >= maxConcurrent) {
    Promise.anyOf(inFlight).get();
    inFlight.removeIf(pr -> { if (pr.isCompleted()) { results.add(pr.get()); return true; } return false; });
  }
  inFlight.add(Async.function(acts::process, item));
}
Promise.allOf(inFlight).get();
inFlight.forEach(pr -> results.add(pr.get()));
```

## Pick First

```java
List<Promise<String>> results = new ArrayList<>();
CancellationScope scope = Workflow.newCancellationScope(() -> {
  results.add(Async.function(acts::sampleActivity, "option1"));
  results.add(Async.function(acts::sampleActivity, "option2"));
});
scope.run();
String first = Promise.anyOf(results).get();
scope.cancel();   // losers must heartbeat (HeartbeatTimeout set) to observe cancellation
```

## Long Running Activity (heartbeat + resume)

```java
public class FileActivitiesImpl implements FileActivities {
  @Override public int processFile(String path) {
    ActivityExecutionContext ctx = Activity.getExecutionContext();
    int start = ctx.getHeartbeatDetails(Integer.class).orElse(0);   // resume point
    List<String> lines = storage.readLines(path);
    for (int i = start; i < lines.size(); i++) {
      handle(lines.get(i));                                          // idempotent per line
      if (i % 100 == 0) ctx.heartbeat(i);                            // surfaces cancellation
    }
    return lines.size();
  }
}
// Stub: .setStartToCloseTimeout(Duration.ofHours(2)).setHeartbeatTimeout(Duration.ofSeconds(30))
```

## Polling

```java
// Infrequent (≥ 1 min): the retry policy is the poll loop; the activity throws until ready
ActivityOptions infrequent = ActivityOptions.newBuilder()
    .setStartToCloseTimeout(Duration.ofSeconds(10))
    .setRetryOptions(RetryOptions.newBuilder()
        .setInitialInterval(Duration.ofMinutes(1))
        .setBackoffCoefficient(1.0)
        .build())
    .build();

// Frequent (≈1 s): loop inside a heartbeating activity (Thread.sleep is fine in Activity code)
public String pollUntilReady(String jobId) {
  ActivityExecutionContext ctx = Activity.getExecutionContext();
  while (true) {
    Status s = api.status(jobId);
    if (s.done()) return s.result();
    ctx.heartbeat(null);
    try { Thread.sleep(1000); } catch (InterruptedException e) { throw Activity.wrap(e); }
  }
}
```

## Async Activity completion (webhook callback)

```java
public class JobActivitiesImpl implements JobActivities {
  @Override public String submitJob(JobInput in) {
    ActivityExecutionContext ctx = Activity.getExecutionContext();
    byte[] token = ctx.getTaskToken();
    jobStore.save(externalService.submit(in.payload()), token);    // persist the token durably
    ctx.doNotCompleteOnReturn();
    return null;                                                   // ignored
  }
}
// Webhook handler:
ActivityCompletionClient completion = client.newActivityCompletionClient();
completion.complete(token, result);           // or completion.completeExceptionally(token, ex)
// Bound the wait with StartToClose / HeartbeatTimeout on the stub.
```

## Delayed Start

```java
WorkflowOptions.newBuilder()
    .setWorkflowId("trial-expiry-" + userId)
    .setTaskQueue("billing")
    .setStartDelay(Duration.ofDays(14))
    .build();
```

## Retry patterns

```java
// Fixed Count — paid / quota-consuming calls
RetryOptions.newBuilder().setMaximumAttempts(3).build();

// Fixed Wall-Time — SLA across all attempts
ActivityOptions.newBuilder()
    .setStartToCloseTimeout(Duration.ofSeconds(10))
    .setScheduleToCloseTimeout(Duration.ofMinutes(2))
    .build();

// Non-Retryable — by type in the policy, or thrown from the activity
RetryOptions.newBuilder().setDoNotRetry("OrderNotFoundError", "ValidationError").build();
throw ApplicationFailure.newNonRetryableFailure("Account " + id + " not found", "AccountNotFoundError");

// Delayed Retry — honour Retry-After for this failure only
throw ApplicationFailure.newFailureWithCauseAndDelay(
    "Rate limited", "RateLimitError", null, Duration.ofSeconds(retryAfterSeconds));

// Fast/Slow — bounded fast phase, then patient slow phase (workflow code)
FooActivities fast = Workflow.newActivityStub(FooActivities.class, ActivityOptions.newBuilder()
    .setStartToCloseTimeout(Duration.ofSeconds(10))
    .setRetryOptions(RetryOptions.newBuilder().setInitialInterval(Duration.ofSeconds(1))
        .setMaximumAttempts(5).build()).build());
FooActivities slow = Workflow.newActivityStub(FooActivities.class, ActivityOptions.newBuilder()
    .setStartToCloseTimeout(Duration.ofSeconds(10))
    .setRetryOptions(RetryOptions.newBuilder().setInitialInterval(Duration.ofMinutes(10))
        .setBackoffCoefficient(1.0).build()).build());   // unlimited attempts
String r;
try { r = fast.call(x); } catch (ActivityFailure e) { r = slow.call(x); }

// Retry Alerting via Metrics — inside the activity
ActivityExecutionContext ctx = Activity.getExecutionContext();
if (ctx.getInfo().getAttempt() > 5) {
  ctx.getMetricsScope()
     .tagged(ImmutableMap.of("activity_type", ctx.getInfo().getActivityType()))
     .counter("HighActivityErrorCount").inc(1);
}
```

## Resumable Activity

```java
private Transfer correction;
@SignalMethod public void correct(Transfer fixed) { correction = fixed; }

@Override public void run(Transfer t) {
  Transfer current = t;
  while (true) {
    try { acts.transfer(current); return; }
    catch (ActivityFailure e) {
      if (!(e.getCause() instanceof ApplicationFailure af) || !"AccountNotFoundError".equals(af.getType())) throw e;
      correction = null;
      notify.operatorNeeded(current, af.getOriginalMessage());
      Workflow.await(() -> correction != null);        // parked, zero resources
      current = correction;
    }
  }
}
```

## Batch Iterator (page + Continue-As-New)

```java
@Override public void run(int offset, int pageSize) {
  List<String> ids = acts.fetchPage(offset, pageSize);
  List<Promise<Void>> ps = new ArrayList<>();
  for (String id : ids) ps.add(Async.procedure(acts::processRecord, id));
  Promise.allOf(ps).get();
  if (ids.size() == pageSize) {
    Workflow.continueAsNew(offset + pageSize, pageSize);
  }
}
```

## Sliding Window (sketch)

```java
// The parent keeps at most windowSize children running; each child Signals completion back.
private final Set<Integer> completed = new HashSet<>();
@SignalMethod public void reportCompletion(int recordId) { completed.add(recordId); }

@Override public int run(SlidingWindowInput in) {
  int next = in.offset(); int running = in.running();
  while (next < in.maxOffset() || running > 0) {
    while (running < in.windowSize() && next < in.maxOffset()) {
      RecordWorkflow child = Workflow.newChildWorkflowStub(RecordWorkflow.class,
          ChildWorkflowOptions.newBuilder()
              .setWorkflowId(Workflow.getInfo().getWorkflowId() + "/" + next)
              .setParentClosePolicy(ParentClosePolicy.PARENT_CLOSE_POLICY_ABANDON)
              .build());
      Async.procedure(child::process, next, Workflow.getInfo().getWorkflowId());
      Workflow.getWorkflowExecution(child).get();   // ensure started
      next++; running++;
    }
    final int before = completed.size();
    Workflow.await(() -> completed.size() > before);
    running -= completed.size() - before;
    // When isContinueAsNewSuggested(): drain handlers, then continueAsNew carrying next/running/completed
  }
  return completed.size();
}
// Child: does the work, then
// Workflow.newExternalWorkflowStub(SlidingWindowWorkflow.class, parentId).reportCompletion(id);
```

## Downstream Rate Limiting

```java
// Dedicated Worker for throttled Activity types; the limit is enforced server-side across the queue
Worker rateLimited = factory.newWorker("rate-limited-tq",
    WorkerOptions.newBuilder().setMaxTaskQueueActivitiesPerSecond(5.0).build());   // same value on every Worker
rateLimited.registerActivitiesImplementations(new PartnerApiActivitiesImpl(httpClient));

// The Workflow routes only those Activities there
PartnerApiActivities partner = Workflow.newActivityStub(PartnerApiActivities.class,
    ActivityOptions.newBuilder().setTaskQueue("rate-limited-tq")
        .setStartToCloseTimeout(Duration.ofSeconds(30)).build());
```

## Priority & Fairness

```java
WorkflowOptions.newBuilder()
    .setTaskQueue("orders")
    .setPriority(Priority.newBuilder()
        .setPriorityKey(1)                // 1 = highest … 5; default 3
        .setFairnessKey("tenant-a")       // Cloud: enable Fairness on the Namespace (paid)
        .setFairnessWeight(2.0f)
        .build())
    .build();
// Activities inherit; override with ActivityOptions.newBuilder().setPriority(...)
```

## Local Activities

```java
ValidationActivities v = Workflow.newLocalActivityStub(ValidationActivities.class,
    LocalActivityOptions.newBuilder().setScheduleToCloseTimeout(Duration.ofSeconds(5)).build());
v.validate(order);   // in-process, no server round trip; must be short and idempotent
```

## Eager Workflow Start

```java
// The starter and the Worker share one WorkflowClient in one process
WorkflowOptions.newBuilder()
    .setWorkflowId(id).setTaskQueue(Shared.TASK_QUEUE)
    .setDisableEagerExecution(false)      // opt in; falls back to normal dispatch if no local slot is free
    .build();
```

## Worker-Specific Task Queue

```java
// Each Worker polls the shared queue AND its own unique queue
String hostQueue = "file-processing-" + hostId;
factory.newWorker("file-processing").registerActivitiesImplementations(new StickyActivitiesImpl(hostQueue));
factory.newWorker(hostQueue).registerActivitiesImplementations(new FileActivitiesImpl());

// Workflow
String q = shared.getHostTaskQueue();                     // runs on any Worker and returns its queue
FileActivities pinned = Workflow.newActivityStub(FileActivities.class, ActivityOptions.newBuilder()
    .setTaskQueue(q)
    .setScheduleToStartTimeout(Duration.ofMinutes(1))     // detect a dead host
    .setStartToCloseTimeout(Duration.ofMinutes(10))
    .build());
String local = pinned.download(url);
String out = pinned.process(local);
pinned.upload(out);
// On a ScheduleToStart timeout, retry the whole sequence from the first Activity on a new host.
```
