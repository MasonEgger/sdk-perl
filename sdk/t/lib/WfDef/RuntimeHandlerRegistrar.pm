# ABOUTME: Fixture workflow that installs a NAMED signal handler at runtime via
# ABOUTME: Temporalio::Workflow->set_signal_handler — drives runtime_handler_registration.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run body parks on a timer with NO handler for 'runtime_sig', so a signal
# delivered while it is parked is buffered. When the timer fires the body
# registers a runtime handler for that name; registration must drain the
# buffered signal immediately (spec R86 buffered-drain contract; sdk-python
# workflow_set_signal_handler parity), and later 'runtime_sig' deliveries
# dispatch straight to the runtime handler. 'finish' releases the body, which
# returns everything the runtime handler received, in arrival order.
class WfDef::RuntimeHandlerRegistrar :isa(Temporalio::Workflow::Definition) {
    field @received;
    field $done = 0;

    async method run :Run () {
        await Temporalio::Workflow::sleep(60);
        Temporalio::Workflow->set_signal_handler('runtime_sig', sub (@args) {
            push @received, join('=', 'runtime_sig', @args);
            return;
        });
        await Temporalio::Workflow::wait_condition(sub { $done });
        return join(',', @received);
    }

    method finish :Signal('finish') () { $done = 1; return }
}

1;
