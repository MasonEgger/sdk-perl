# ABOUTME: Fixture workflow that schedules a Nexus operation AFTER cancellation
# ABOUTME: has already been requested — drives the pre-scheduled-cancel path
# ABOUTME: (T-nexus-8 last clause): start_operation raises Cancelled immediately.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled;

# The :Run first parks on a timer; a CancelWorkflow job then sets the run
# cancel-requested flag and unwinds that await with Cancelled. The body catches
# that, then schedules a Nexus operation while the run is ALREADY
# cancel-requested. start_nexus_operation honours the pre-scheduled cancel: the
# start await raises Cancelled immediately, which the body catches and reports as
# a marker so the test can assert the start never resolved normally.
class WfDef::NexusPreCancelled :isa(Temporalio::Workflow::Definition) {
    async method run :Run {
        eval { await Temporalio::Workflow::sleep(60); 1 }
            or do {
                # swallow the timer cancellation; proceed to schedule the op.
            };

        my $nc = Temporalio::Workflow::create_nexus_client(
            endpoint => 'my-endpoint',
            service  => 'my-service',
        );
        my $raised = 0;
        eval {
            await $nc->start_operation('say-hello', 'world');
            1;
        } or do {
            my $err = $@;
            $raised = 1
                if ref $err
                && $err->isa('Temporalio::Exception::Cancelled');
        };
        return $raised ? 'pre-cancelled' : 'started';
    }
}

1;
