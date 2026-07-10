# Temporalio-SDK

The Perl [Temporal](https://temporal.io) SDK — the `Temporalio::*` modules.
This is the top distribution of the
[`temporalio/sdk-perl`](https://github.com/temporalio/sdk-perl) monorepo; see
the [repository README](../README.md) for the full picture and the layered
`Alien::Temporalio::Core` / `Alien::Temporalio::PerlBridge` build chain.

It drives the Rust `sdk-core` over its C ABI via
[FFI::Platypus](https://metacpan.org/pod/FFI::Platypus), with an async API built
on [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait) over
[IO::Async](https://metacpan.org/pod/IO::Async). Workflows run in a deterministic
scheduler ([`Temporalio::Workflow::Runner`](lib/Temporalio/Workflow/Runner.pm))
that resolves workflow futures from activation jobs rather than from real timers.

> **Status: pre-1.0.** The public API is taking shape against
> [`../spec.md`](../spec.md). Expect changes.

## Requirements

- **Perl 5.38.0+** (for `feature 'class'`). See the
  [repository README](../README.md#platform-notes) for RHEL/macOS/Windows notes.
- The native dependencies `Alien::Temporalio::Core` and
  `Alien::Temporalio::PerlBridge`, which build `sdk-core` and our Rust callback
  shim. Install them first (a Rust `stable` toolchain is required at build time).

## Installation

```bash
cpanm git+https://github.com/temporalio/sdk-perl.git#main/alien-core
cpanm git+https://github.com/temporalio/sdk-perl.git#main/alien-perl-bridge
cpanm git+https://github.com/temporalio/sdk-perl.git#main/sdk
```

To build `sdk-core` from a local `sdk-rust` checkout rather than fetching the
pinned tag, set `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH` to its path before
installing.

## Usage

A minimal workflow + activity, a worker that executes them, and a client that
starts the workflow:

```perl
use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class GreetingWorkflow :isa(Temporalio::Workflow::Definition) {
    async method run :Run('GreetingWorkflow') ($name = 'World') {
        return await Temporalio::Workflow::execute_activity(
            'SayHello', args => [$name], start_to_close_timeout => 30,
        );
    }
}
```

```perl
use Future::AsyncAwait;
use IO::Async::Loop;
use Temporalio::Runtime;
use Temporalio::Client;
use Temporalio::Worker;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);
my $client  = $loop->await(
    Temporalio::Client->connect('localhost:7233', namespace => 'default', runtime => $runtime)
)->get;

my $worker = Temporalio::Worker->new(
    client => $client, task_queue => 'hello-world',
    workflows => ['GreetingWorkflow'], activities => ['Activities'],
);
$loop->await($worker->run)->get;
```

The complete runnable example is in [`examples/hello-world/`](examples/hello-world/).

## Key modules

| Module | Purpose |
|--------|---------|
| [`Temporalio::Client`](lib/Temporalio/Client.pm) | Connect to a server; start / signal / query / list workflows. |
| [`Temporalio::Client::WorkflowHandle`](lib/Temporalio/Client/WorkflowHandle.pm) | Handle to a running workflow; fetch its result, signal, query, cancel. |
| [`Temporalio::Worker`](lib/Temporalio/Worker.pm) | Poll a task queue and execute workflows and activities. |
| [`Temporalio::Workflow`](lib/Temporalio/Workflow.pm) | The in-workflow API (timers, activities, signals, deterministic time/RNG). |
| [`Temporalio::Workflow::Definition`](lib/Temporalio/Workflow/Definition.pm) | Base class for workflow definitions (`:Run`, `:Signal`, `:Query`, `:Update`). |
| [`Temporalio::Activity::Definition`](lib/Temporalio/Activity/Definition.pm) | Base class for activity definitions (`:Defn`). |
| [`Temporalio::Activity`](lib/Temporalio/Activity.pm) | The in-activity API (info, heartbeat, cancellation). |
| [`Temporalio::Runtime`](lib/Temporalio/Runtime.pm) | The sdk-core runtime bound to an `IO::Async` loop. |
| [`Temporalio::Exception`](lib/Temporalio/Exception.pm) | Base class for every `Temporalio::Exception::*` error. |

Every public class ships hand-written POD; run `perldoc Temporalio::Client` (etc.)
after installing.

## Development

```bash
prove -lj4 t          # full test suite (unit / replay / integration)
prove -lj4 xt         # author tests (POD coverage + syntax)
dzil test             # distribution check
```

Integration tests under `t/integration/` `skip_all` when the `temporal` CLI /
dev server is unavailable, so a green offline run is expected.

## License

MIT. Copyright Temporal Technologies Inc.
