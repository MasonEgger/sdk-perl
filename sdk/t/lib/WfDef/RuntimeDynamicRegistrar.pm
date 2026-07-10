# ABOUTME: Fixture workflow that installs a DYNAMIC signal handler at runtime via
# ABOUTME: Temporalio::Workflow->set_dynamic_signal_handler — drives runtime_handler_registration.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run body parks on a timer with no handlers beyond 'finish', so signals
# under any other name are buffered. When the timer fires the body registers a
# runtime DYNAMIC catch-all; registration must drain EVERY buffered signal in
# arrival order (spec R86; sdk-python workflow_set_signal_handler with name
# None drains the whole buffer). 'finish' has a named handler, so it keeps
# routing there, never to the catch-all.
class WfDef::RuntimeDynamicRegistrar :isa(Temporalio::Workflow::Definition) {
    field @received;
    field $done = 0;

    async method run :Run () {
        await Temporalio::Workflow::sleep(60);
        Temporalio::Workflow->set_dynamic_signal_handler(sub ($name, @args) {
            push @received, join('=', $name, @args);
            return;
        });
        await Temporalio::Workflow::wait_condition(sub { $done });
        return join(',', @received);
    }

    method finish :Signal('finish') () { $done = 1; return }
}

1;
