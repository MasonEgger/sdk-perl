# Greet with Signal

A signal-driven Temporal Perl SDK example: a workflow that **waits for a signal**
before it can finish. The workflow parks on `wait_condition` until a `setName`
signal arrives, exposes a `currentName` query so you can inspect its in-flight
state, then greets and completes.

## Layout

```
greet-with-signal/
├── lib/
│   └── GreetWithSignal/
│       └── GreetingWorkflow.pm   # waits for setName, answers currentName, greets
├── worker.pl                     # runs the worker (polls the task queue)
└── starter.pl                    # starts the workflow, signals it, queries, prints
```

## Run it

1. Start a local Temporal server (the `temporal` CLI's dev server):

   ```bash
   temporal server start-dev
   ```

2. In one terminal, start the worker. It connects to the server, registers the
   workflow, and polls the `greet-with-signal` task queue until you stop it with
   Ctrl-C:

   ```bash
   perl -Ilib worker.pl
   ```

   (`-Ilib` puts `examples/greet-with-signal/lib` on `@INC`; the SDK itself must
   already be installed, or add its `lib` too.)

3. In another terminal, start a workflow, signal it, and wait for its result:

   ```bash
   perl -Ilib starter.pl Ada
   # current name before signal: ''
   # sent setName signal: 'Ada'
   # current name after signal:  'Ada'
   # Hello, Ada!
   ```

   The name argument is optional (defaults to `Temporal`).

## Configuration

Both scripts honor the same environment overrides:

| Variable               | Default              | Meaning                       |
|------------------------|----------------------|-------------------------------|
| `TEMPORAL_ADDRESS`     | `localhost:7233`     | server `host:port`            |
| `TEMPORAL_NAMESPACE`   | `default`            | namespace                     |
| `TEMPORAL_TASK_QUEUE`  | `greet-with-signal`  | task queue the worker polls   |

## How it fits together

```mermaid
sequenceDiagram
    participant S as starter.pl
    participant Server as Temporal Server
    participant W as worker.pl
    S->>Server: start GreetWithSignal
    Server->>W: workflow task (InitializeWorkflow)
    Note over W: :Run parks on wait_condition(name set?)
    S->>Server: query currentName
    Server->>W: query task
    W-->>Server: "" (empty — not signalled yet)
    Server-->>S: ""
    S->>Server: signal setName("Ada")
    Server->>W: workflow task (SignalWorkflow)
    Note over W: handler sets name; wait_condition resumes :Run
    W-->>Server: CompleteWorkflow("Hello, Ada!")
    S->>Server: await result
    Server-->>S: "Hello, Ada!"
```

The workflow code is deterministic — it never does I/O. It reacts to a **signal**
(an asynchronous message that mutates state) and answers a **query** (a
read-only request that observes state without changing it). The signal is what
unblocks the workflow: until it arrives, the `:Run` body stays parked on
`wait_condition`.
