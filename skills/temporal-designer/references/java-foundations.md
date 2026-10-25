# Java Foundations for Temporal

The catalog's runnable samples were written against `io.temporal:temporal-sdk` 1.27.0 and Java 17. Check method names against the SDK version the user's project uses.

## Contents
1. Dependencies
2. Interfaces and implementations
3. Activity options: timeouts and retries
4. Worker and client setup
5. Starting Workflows and Workflow ID policies
6. Determinism rules
7. Failures and errors
8. Testing and replay
9. Versioning
10. Observability

---

## 1. Dependencies

```xml
<dependency>
  <groupId>io.temporal</groupId>
  <artifactId>temporal-sdk</artifactId>
  <version>${temporal.version}</version>
</dependency>
<dependency>
  <groupId>io.temporal</groupId>
  <artifactId>temporal-testing</artifactId>
  <version>${temporal.version}</version>
  <scope>test</scope>
</dependency>
```

For Spring Boot, `io.temporal:temporal-spring-boot-starter` auto-registers Workers from configuration.

## 2. Interfaces and implementations

```java
@WorkflowInterface
public interface OrderWorkflow {
  @WorkflowMethod
  OrderResult run(OrderInput input);

  @SignalMethod
  void cancel(String reason);

  @UpdateMethod
  String addItem(Item item);

  @UpdateValidatorMethod(updateName = "addItem")
  void validateAddItem(Item item);           // throw to reject; must not mutate state

  @QueryMethod
  OrderStatus status();
}

@ActivityInterface
public interface PaymentActivities {
  @ActivityMethod
  ChargeResult charge(ChargeRequest req);    // must be idempotent (pass an idempotency key)
}
```

- A Workflow implementation is a plain class with no shared static state. The SDK creates one instance per execution.
- Use records or POJOs with a no-arg constructor for inputs and outputs, so Jackson can serialize them. Prefer one input object over many parameters, so fields can be added later without breaking compatibility.
- Signal and Update handlers change fields. The `@WorkflowMethod` reacts with `Workflow.await(() -> condition)`.

## 3. Activity options: timeouts and retries

```java
private final PaymentActivities payments = Workflow.newActivityStub(
    PaymentActivities.class,
    ActivityOptions.newBuilder()
        .setStartToCloseTimeout(Duration.ofSeconds(30))      // always set; resets each attempt
        // .setScheduleToCloseTimeout(Duration.ofMinutes(10)) // total budget across attempts
        // .setHeartbeatTimeout(Duration.ofSeconds(10))       // for long-running activities
        // .setScheduleToStartTimeout(...)                    // only for host-specific queues
        .setRetryOptions(RetryOptions.newBuilder()
            .setInitialInterval(Duration.ofSeconds(1))
            .setBackoffCoefficient(2.0)
            .setMaximumInterval(Duration.ofMinutes(1))
            // .setMaximumAttempts(5)
            .setDoNotRetry("ValidationError", "OrderNotFoundError")
            .build())
        .build());
```

| Timeout | Scope | Guidance |
| :--- | :--- | :--- |
| StartToClose | One attempt | **Strongly recommended.** Set it above the normal duration, and give the Activity's own calls (HTTP, DB) shorter client timeouts |
| ScheduleToClose | All attempts | Use for an SLA (Fixed Wall-Time) |
| ScheduleToStart | Time spent queued | Leave unset; monitor `temporal_activity_schedule_to_start_latency` instead |
| Heartbeat | Gap between heartbeats | Keep short for long Activities; required for cancellation to arrive |

Set timeouts and retries for each Activity individually; a single blanket setting is rarely right. Leave Workflow execution and run timeouts at their default (infinite). Use timers for business deadlines. A Workflow retry policy is generally not recommended.

Local Activity stub:

```java
private final ValidationActivities validation = Workflow.newLocalActivityStub(
    ValidationActivities.class,
    LocalActivityOptions.newBuilder()
        .setScheduleToCloseTimeout(Duration.ofSeconds(5))   // includes retries; keep well under the WFT timeout
        .build());
```

## 4. Worker and client setup

```java
public final class WorkerMain {
  public static void main(String[] args) {
    WorkflowServiceStubs service = WorkflowServiceStubs.newServiceStubs(
        WorkflowServiceStubsOptions.newBuilder()
            .setTarget(System.getenv().getOrDefault("TEMPORAL_ADDRESS", "localhost:7233"))
            // For Temporal Cloud: configure mTLS (setSslContext) or API-key auth
            .build());
    WorkflowClient client = WorkflowClient.newInstance(service,
        WorkflowClientOptions.newBuilder()
            .setNamespace(System.getenv().getOrDefault("TEMPORAL_NAMESPACE", "default"))
            .build());

    WorkerFactory factory = WorkerFactory.newInstance(client);

    Worker worker = factory.newWorker("orders",
        WorkerOptions.newBuilder()
            .setMaxConcurrentActivityExecutionSize(200)
            .setMaxConcurrentWorkflowTaskExecutionSize(200)
            .build());
    worker.registerWorkflowImplementationTypes(OrderWorkflowImpl.class);

    // Activity Dependency Injection: build expensive clients once, pass them into the constructor
    HttpClient http = HttpClient.newHttpClient();
    DataSource ds = DataSources.create();
    worker.registerActivitiesImplementations(new PaymentActivitiesImpl(http), new InventoryActivitiesImpl(ds));

    factory.start();
  }
}
```

- Run at least 2 Worker processes for each Task Queue. Every Worker that polls a queue must register the same types.
- Read secrets (mTLS keys, API keys) from the environment or a secret manager, never from source code.
- Add a separate Task Queue only for a real reason: a separate deployment unit, rate limiting or flow control, or host or hardware routing.

## 5. Starting Workflows and Workflow ID policies

```java
OrderWorkflow wf = client.newWorkflowStub(OrderWorkflow.class,
    WorkflowOptions.newBuilder()
        .setWorkflowId("order-" + orderId)                  // business key = natural idempotency
        .setTaskQueue("orders")
        .setWorkflowIdReusePolicy(WorkflowIdReusePolicy.WORKFLOW_ID_REUSE_POLICY_REJECT_DUPLICATE)
        // .setWorkflowIdConflictPolicy(WorkflowIdConflictPolicy.WORKFLOW_ID_CONFLICT_POLICY_USE_EXISTING)
        // .setStartDelay(Duration.ofHours(1))               // Delayed Start
        // .setPriority(Priority.newBuilder().setPriorityKey(1).build())
        .build());
WorkflowExecution exec = WorkflowClient.start(wf::run, input);   // async start
// OrderResult r = wf.run(input);                                // blocking start + wait
```

- Never base logic on the Run ID, which changes on retry and on Continue-As-New.
- Don't reuse the same Workflow ID at a very high frequency.

## 6. Determinism rules (Workflow code only)

| Don't use | Use instead |
| :--- | :--- |
| `System.currentTimeMillis()`, `Instant.now()` | `Workflow.currentTimeMillis()` |
| `Thread.sleep` | `Workflow.sleep(Duration)` / `Workflow.newTimer(Duration)` |
| `new Thread`, `ExecutorService`, `CompletableFuture` | `Async.function` / `Async.procedure`, `Promise` |
| `UUID.randomUUID()`, `new Random()` | `Workflow.randomUUID()`, `Workflow.newRandom()` |
| I/O, HTTP, DB, reading env/config | An Activity (or a Local Activity) |
| `synchronized`, Java locks | Not needed (the Workflow runs cooperatively on one thread at a time); use `Workflow.await` |
| Iterating a `HashMap`/`HashSet` where order affects commands | `LinkedHashMap` / `TreeMap` |
| Mutable static fields | Instance fields |
| `Workflow.sideEffect` for anything that can fail | An Activity |

Timers shorter than 1 s aren't reliable.

## 7. Failures and errors

- An Activity that throws is retried according to its policy. When retries run out, the Workflow sees an `ActivityFailure` whose `getCause()` is often an `ApplicationFailure` with a `getType()`.
- Throw `ApplicationFailure.newNonRetryableFailure(message, type)` from an Activity to fail fast. The alternative is to list the type in `setDoNotRetry`.
- Throw `ApplicationFailure.newFailureWithCauseAndDelay(message, type, cause, Duration)` to override the next retry delay (Delayed Retry).
- In Workflow code, a thrown `ApplicationFailure` (or any `TemporalFailure`) **fails the Workflow**. Any other unchecked exception **fails the Workflow Task**, which is retried indefinitely; this is often what you want for bugs. To fail the Workflow on other exception types, set `WorkflowImplementationOptions.setFailWorkflowExceptionTypes(...)` when registering.
- Use `Workflow.wrap(e)` to rethrow checked exceptions.

## 8. Testing and replay

```java
class OrderWorkflowTest {
  @RegisterExtension
  static final TestWorkflowExtension ext = TestWorkflowExtension.newBuilder()
      .setWorkflowTypes(OrderWorkflowImpl.class)
      .setDoNotStart(true)
      .build();

  @Test
  void chargesAndCompletes(TestWorkflowEnvironment env, Worker worker, OrderWorkflow wf) {
    PaymentActivities payments = mock(PaymentActivities.class, withSettings().withoutAnnotations());
    when(payments.charge(any())).thenReturn(new ChargeResult("ok"));
    worker.registerActivitiesImplementations(payments);
    env.start();

    OrderResult r = wf.run(new OrderInput("o-1"));
    assertEquals("COMPLETED", r.status());
  }
}
```

- The time-skipping test environment fast-forwards through timers.
- Before deploying a change to Workflow code, run a **replay test** against histories downloaded from production:

```java
WorkflowReplayer.replayWorkflowExecutionFromResource("histories/order-1.json", OrderWorkflowImpl.class);
```

## 9. Versioning

- **Patching:** a version-gated code path inside the Workflow.

  ```java
  int v = Workflow.getVersion("add-fraud-check", Workflow.DEFAULT_VERSION, 1);
  if (v >= 1) { fraud.check(order); }
  ```

  Remove a patch only after every execution that could replay it has closed and its retention period has expired. Don't let patches pile up.
- **Worker Versioning (Worker Deployments):** pin executions to the Worker build that started them. This suits short-lived Workflows. Check its current release status in the Temporal docs before recommending it.
- Long-running entities should Continue-As-New regularly, so each new run starts on the latest code.

## 10. Observability

- SDK metrics are exported through a Micrometer/Prometheus scope configured on `WorkflowServiceStubsOptions.setMetricsScope(...)`. Alert on `temporal_activity_schedule_to_start_latency`, `temporal_workflow_task_execution_latency`, and custom attempt counters.
- Use Search Attributes for operational filtering only. They are not encrypted by codecs, so keep personal data out, and they are eventually consistent (about 1–2 s). Use Queries or an external store for business reads.
- Compress payloads with a codec by default. If you encrypt, plan key rotation.
