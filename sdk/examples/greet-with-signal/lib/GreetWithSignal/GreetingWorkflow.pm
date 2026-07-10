# ABOUTME: greet-with-signal example — a workflow that waits for a `setName`
# ABOUTME: signal, exposes a `currentName` query, then greets and completes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# A signal-driven workflow (spec section 10.1). The :Run body blocks on
# wait_condition until a `setName` signal sets the name, then returns a greeting.
# While the workflow is parked, the `currentName` query reads the in-flight
# state without disturbing the run. Workflow code is deterministic — it performs
# no I/O; it reacts to signals and answers queries against its own state.
class GreetWithSignal::GreetingWorkflow :isa(Temporalio::Workflow::Definition) {
    field $name = '';

    # Block until a signal sets the name, then greet. wait_condition re-checks
    # its predicate after each signal is applied, so the body resumes in the
    # activation that carries the `setName` signal.
    async method run :Run('GreetWithSignal') () {
        await Temporalio::Workflow::wait_condition(sub { length $name });
        return "Hello, $name!";
    }

    # Signal handler: set the name the workflow will greet.
    method set_name :Signal('setName') ($value) {
        $name = $value;
        return;
    }

    # Query handler: read the current name (empty until the signal arrives).
    method current_name :Query('currentName') () {
        return $name;
    }
}

1;
