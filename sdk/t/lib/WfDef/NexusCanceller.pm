# ABOUTME: Fixture workflow that starts a Nexus operation and cancels it when a
# ABOUTME: "cancel" signal arrives — drives explicit $handle->cancel (T-nexus-8)
# ABOUTME: and the cancellation_type echo. The op's cancellation_type is set per run.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts a Nexus operation (whose cancellation_type the fixture sets)
# and parks on its result. A :Signal handler stashes the request to cancel; the
# body cancels the handle when the flag is set, which emits
# RequestCancelNexusOperation (unless abandon). After cancellation the body
# awaits the result, which a ResolveNexusOperation{cancelled} settles to a
# NexusOperation/Cancelled (or, under try_cancel/abandon, the handle's own
# Cancelled raises immediately).
class WfDef::NexusCanceller :isa(Temporalio::Workflow::Definition) {
    field $cancel_requested = 0;

    async method run :Run ($cancellation_type = 'wait_cancellation_completed') {
        my $nc = Temporalio::Workflow::create_nexus_client(
            endpoint => 'my-endpoint',
            service  => 'my-service',
        );
        my $handle = await $nc->start_operation(
            'say-hello', 'world',
            cancellation_type => $cancellation_type,
        );
        await Temporalio::Workflow::wait_condition(sub { $cancel_requested });
        $handle->cancel;
        return await $handle->result;
    }

    method want_cancel :Signal('cancel') (@args) {
        $cancel_requested = 1;
        return;
    }
}

1;
